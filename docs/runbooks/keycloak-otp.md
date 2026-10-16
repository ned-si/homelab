# Keycloak OTP: enroll, reset, break-glass

Who needs a one-time code (TOTP: 6 digits, 30 s, SHA1, any authenticator app):

| Login | Who | Where it is set |
| --- | --- | --- |
| Realm `homelab`, every app and the account console | members of group `admins` (realm role `mfa-required`) | `platform/keycloak/realm/platform.conf`: `mfa_role`, `mfa_groups` |
| Realm `homelab` | everyone else: only if they set up OTP themselves | same file: the `-otp` subflows |
| Realm `master`, the Keycloak admin console | every user (`admin`) | flow `browser-otp`, `platform.conf` `automation_client` |
| Password grants (`direct grant` flows), the `keycloak-realm-settings` Job | unchanged: no new OTP step; the Job uses client credentials | |

The Job `keycloak-realm-settings` applies all of it after every sync of the
`keycloak` Application. Check it:

```sh
kubectl -n keycloak logs job/keycloak-realm-settings | grep -E 'login as|mfa|otp|OTP|browserFlow|FAIL'
```

Expected: `ok   login as client realm-settings`, `ok   realm role mfa-required
groups=admins`, `ok   flow browser-loa: 13 executions`, `ok   master
browserFlow=browser-otp`, and no `FAIL` line.

## Enroll

Preconditions: an authenticator app on the phone (Aegis, 2FAS, Google
Authenticator, 1Password, Bitwarden).

1. Log in as usual: an app (realm `homelab`) or
   `https://auth.lilalala.com/admin/master/console/` (realm `master`).
2. After the password, Keycloak shows "Mobile Authenticator Setup" with a QR
   code. Scan it, type the 6-digit code, give the device a name, Submit.
3. Every later password login asks for the code. The SSO cookie still logs
   you in without one until it expires (platform tools: 12 h).

Once `admin` has OTP, `kcadm.sh config credentials --user admin` (a password
grant to `admin-cli`) fails with `invalid_grant`: use the client
`realm-settings` as in [Break-glass](#break-glass).

Expected: the login completes. Realm `homelab`: Account console
(`https://auth.lilalala.com/realms/homelab/account/`), Account security,
Signing in lists the authenticator under "Two-factor authentication".

To make an admin enroll now instead of at the next password login, sign out
their sessions: master admin console, realm `homelab`, Users, the user,
Sessions, Sign out.

## Reset a lost authenticator

A user of realm `homelab` (including the operator's own account): master
admin console, realm `homelab`, Users, the user, Credentials, the `otp` row,
Delete. The next login asks to enroll again.

The `admin` user of realm `master` (or when the admin console is out of
reach): delete its OTP credential with the automation client, as in
[Break-glass](#break-glass), step 2 with `master admin`.

## Break-glass

When no human can log in to the Keycloak admin console (lost phone, broken
flow), the master client `realm-settings` still can: its secret is in
`platform/secrets/keycloak-automation.sops.yaml` and in the cluster Secret
`keycloak/keycloak-automation`, and it has the master role `admin`.

Preconditions: `kubectl` to the cluster (LAN or tailnet); Keycloak running.

1. Check the client logs in. The secret goes through stdin, never the
   terminal:

   ```sh
   kubectl -n keycloak get secret keycloak-automation \
     -o jsonpath='{.data.REALM_SETTINGS_CLIENT_SECRET}' | base64 -d |
     kubectl -n keycloak exec -i deploy/keycloak -- bash -c '
       read -r s
       /opt/keycloak/bin/kcadm.sh config credentials --config /tmp/bg.cfg \
         --server http://localhost:8080 --realm master --client realm-settings --secret "$s"
       rm -f /tmp/bg.cfg'
   ```

   Expected: `Logging into http://localhost:8080 as service-account-realm-settings of realm master`.

2. Delete the OTP credential of `<user>` in `<realm>` (`master admin`, or
   `homelab <username>`):

   ```sh
   kubectl -n keycloak get secret keycloak-automation \
     -o jsonpath='{.data.REALM_SETTINGS_CLIENT_SECRET}' | base64 -d |
     kubectl -n keycloak exec -i deploy/keycloak -- bash -c '
       K=/opt/keycloak/bin/kcadm.sh; C="--config /tmp/bg.cfg"
       read -r s
       $K config credentials $C --server http://localhost:8080 --realm master \
         --client realm-settings --secret "$s" >/dev/null
       uid=$($K get users -r "$0" $C -q username="$1" -q exact=true --fields id --format csv --noquotes)
       for c in $($K get "users/$uid/credentials" -r "$0" $C --fields id,type --format csv --noquotes | sed -n "s/,otp\$//p"); do
         $K delete "users/$uid/credentials/$c" -r "$0" $C && echo "deleted OTP credential $c of $1"
       done
       rm -f /tmp/bg.cfg' <realm> <user>
   ```

   Expected: the `Logging into ...` line, then `deleted OTP credential <id>
   of <user>`. Log in: Keycloak asks to enroll a new authenticator.

3. If the flow itself is broken, bind the built-in flow while you fix it in
   git (the next Job run binds the managed flow again). Same command as step
   2, with the two `$K get`/`delete` lines replaced by:

   ```sh
   $K update realms/master $C -s browserFlow=browser
   ```

   Expected: no output. The master login asks for the password only.

If the client secret fails too (`invalid_client`), create a temporary admin
service account with Keycloak's recovery command. It needs every Keycloak
pod stopped, so Argo CD must not restore the Deployment meanwhile:

1. Pull request: remove `automated:` from `clusters/homelab/platform/keycloak.yaml`; merge.
2. Stop Keycloak: `kubectl -n keycloak scale deploy/keycloak --replicas=0`.
3. Run the recovery against the database, with the server's image (keep the
   tag equal to `platform/keycloak/deployment.yaml`):

   ```sh
   kubectl apply -f - <<'EOF'
   apiVersion: batch/v1
   kind: Job
   metadata:
     name: keycloak-recovery
     namespace: keycloak
   spec:
     backoffLimit: 0
     template:
       metadata:
         labels:
           app.kubernetes.io/name: keycloak
       spec:
         restartPolicy: Never
         containers:
           - name: keycloak
             image: quay.io/keycloak/keycloak:26.8.1
             args: [bootstrap-admin, service, --client-id, temp-admin,
                    "--client-secret:env=KC_BOOTSTRAP_ADMIN_PASSWORD", --no-prompt]
             env:
               - { name: KC_DB, value: postgres }
               - { name: KC_CACHE, value: local }
               - name: KC_DB_URL
                 valueFrom: { secretKeyRef: { name: keycloak-db-app, key: jdbc-uri } }
               - name: KC_BOOTSTRAP_ADMIN_PASSWORD
                 valueFrom: { secretKeyRef: { name: keycloak-admin, key: password } }
   EOF
   kubectl -n keycloak wait --for=condition=complete job/keycloak-recovery --timeout=300s
   ```

   Expected: `job.batch/keycloak-recovery condition met`. The temporary
   service account `temp-admin` exists; its secret is the `keycloak-admin`
   key `password`.
4. `kubectl -n keycloak delete job keycloak-recovery`, then
   `kubectl -n keycloak scale deploy/keycloak --replicas=1`, and revert step 1.
5. Run step 2 above with `--client temp-admin` and the secret from Secret
   `keycloak-admin` key `password`, for `master admin`. With the admin's OTP
   gone, the Job's password fallback works: sync the `keycloak` Application
   (`argocd --core app sync keycloak` if SSO is down); the Job sets the
   `realm-settings` secret from git again and logs `ok   master client
   realm-settings login=ok`.
6. Delete the client `temp-admin` (master realm, Clients) and enroll the
   admin again.

Rollback: none needed. Deleting an OTP credential only makes the next login
enroll again; the Job puts the managed flows and roles back on its next run.
