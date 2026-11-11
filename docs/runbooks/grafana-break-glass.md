# Grafana break-glass login

Everyday login to `https://grafana.lilalala.com` is Keycloak (client
`grafana-oauth`): members of group `admins` get the org role Admin
(`role_attribute_path` in `platform/kube-prometheus-stack/values.yaml`),
anyone else who can log in gets Viewer. The login page sends straight to
Keycloak and has no password form (`auth.disable_login_form`, pentest
2026-11-10 E2), so every interactive login has Keycloak's OTP. When Keycloak
is down or the mapping breaks, Grafana's built-in user `admin` still works
with a password, through the API or after turning the form back on:

| What | Where |
| --- | --- |
| Password | the password manager; sealed in `platform/secrets/grafana-admin.sops.yaml`, key `admin-password`; cluster Secret `monitoring/grafana-admin` |
| Consumers | the `grafana` container (`GF_SECURITY_ADMIN_PASSWORD`) and the dashboard and datasource sidecars (`REQ_PASSWORD`, for the provisioning reload calls), through `grafana.admin.existingSecret` |
| Grafana role | Server Admin, org Admin |

Grafana applies `GF_SECURITY_ADMIN_PASSWORD` only when it creates
`grafana.db`. The database lives on PVC `monitoring/kube-prometheus-stack-grafana`,
so after a change of the Secret the stored password stays the old one until
[Set the stored password](#set-the-stored-password) runs.

## Log in

From a terminal, through the API (the password goes through stdin, never the
command line):

```sh
kubectl -n monitoring get secret grafana-admin -o jsonpath='{.data.admin-password}' | base64 -d |
  { read -r p; printf 'user = "admin:%s"\n' "$p"; } |
  curl -s -m 10 -K - https://grafana.lilalala.com/api/user | jq '{login, isGrafanaAdmin}'
```

Expected: `{"login": "admin", "isGrafanaAdmin": true}`. `{"message": "Invalid
username or password"}` means the database holds another password: set it as
below.

In the browser, only while Keycloak is broken: pause Argo CD on the
Application, turn the form back on, and undo both when done.

```sh
kubectl -n argo annotate application kube-prometheus-stack argocd.argoproj.io/skip-reconcile=true
kubectl -n monitoring set env deploy/kube-prometheus-stack-grafana -c grafana \
  GF_AUTH_DISABLE_LOGIN_FORM=false GF_AUTH_GENERIC_OAUTH_AUTO_LOGIN=false
```

Then open `https://grafana.lilalala.com/login` and sign in as `admin`. When
done, remove the two variables first (with server-side apply, self-heal does
not remove fields another manager added), then the annotation:

```sh
kubectl -n monitoring set env deploy/kube-prometheus-stack-grafana -c grafana \
  GF_AUTH_DISABLE_LOGIN_FORM- GF_AUTH_GENERIC_OAUTH_AUTO_LOGIN-
kubectl -n argo annotate application kube-prometheus-stack argocd.argoproj.io/skip-reconcile-
```

Expected: the login page sends straight to Keycloak again.

## Set the stored password

Needed once after the Secret first lands on an existing database, and after
every rotation. Preconditions: `kubectl` to the cluster (LAN or tailnet), the
Grafana pod Running.

```sh
kubectl -n monitoring get secret grafana-admin -o jsonpath='{.data.admin-password}' | base64 -d |
  kubectl -n monitoring exec -i deploy/kube-prometheus-stack-grafana -c grafana -- \
    grafana cli --homepath /usr/share/grafana --config /etc/grafana/grafana.ini \
    admin reset-admin-password --password-from-stdin
```

Expected: `Admin password changed successfully`. Then run the terminal check
in [Log in](#log-in).

The sidecars read `REQ_PASSWORD` at start, so they keep the value the pod
started with. When the Secret changed while the pod ran, restart it:

```sh
kubectl -n monitoring rollout restart deploy/kube-prometheus-stack-grafana
kubectl -n monitoring rollout status deploy/kube-prometheus-stack-grafana --timeout=180s
kubectl -n monitoring logs deploy/kube-prometheus-stack-grafana -c grafana | grep 'provisioning/.*/reload' | tail -2
```

Expected: `successfully rolled out`, and the reload requests from `[::1]`
with `status=200` (`status=401` means the stored password and the Secret
differ).

## Rotate

1. Generate a value: `openssl rand -base64 33 | tr -d '\n=+/' | cut -c1-40`.
   Put it in the password manager and in `secrets.local.env` as
   `GRAFANA_ADMIN_PASSWORD`.
2. Re-seal: `task secrets:edit -- platform/secrets/grafana-admin.sops.yaml`
   (key `admin-password`), and set the file's date in
   `ci/secret-rotation.tsv`. Pull request, merge.
3. Once `secrets-platform` has synced, run
   [Set the stored password](#set-the-stored-password), including the restart.

Rollback: put the old value back the same way. A wrong stored password only
blocks the break-glass login; Keycloak logins do not use it.
