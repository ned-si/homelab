# Tasks: access-identity

Requirement numbers in brackets. New work in this area adds a task here first.

## Done

- [x] 1. Rotate the leaked credentials, add the age key, encrypt to it only;
      rotate the NAS keys and the Cloudflare token. [5.1] (#96, #97, #99, #101)
- [x] 2. Realm session lifetimes as code. [1.1, 3.1] (#182)
- [x] 3. Long sessions in Mealie, Paperless and Seafile. [3.3] (#188, #189, #190)
- [x] 4. Platform tools ask again after 12 hours. [3.2] (#200)
- [x] 5. Delete the getting-started client; exact redirect URIs. [1.2] (#242, #278)
- [x] 6. Enforce `restricted` Pod Security where it already passes. [6.3] (#346)
- [x] 7. Disable the Argo CD local admin account. [2.3] (#348)
- [x] 8. Read-only access for automation (Kubernetes, Argo CD). [5.4] (#353)
- [x] 9. Security headers per route, gated in DAST; accept upstream JS findings
      on the book apps. [6.1, 6.2] (#465, #467)
- [x] 10. Per-app access by group, enforced at login. [2.1, 2.2] (#468)
- [x] 11. Rotation periods and a Secret age alert. [5.2, 5.3] (#471)
- [x] 12. Tailscale operator with the API proxy; tailnet policy from git. [4.1, 4.2]
      (#487, #495)
- [x] 13. Read-only Headlamp on the tailnet and its SSO fixes. [4.3] (#492, #494, #498)
- [x] 14. Remote access docs for the Mac and the phone. (#501)
- [x] 15. Exit nodes on the home connection. [4.4] (#503)
- [x] 24. Talos API on the tailnet: `tag:talos` owned by the operator's
      client, owner and admins to `tag:talos:50000` only. [4.5] (#527)
- [x] 25. ExposedSecretReports out of `view`: an admission policy strips the
      reader aggregation labels the trivy chart sets. [5.5] (#523)
- [x] 26. TOTP for `admins` and the Keycloak admin; the realm Job on its own
      master client; enrol, reset and break-glass runbook. [7.1-7.5] (#546)

## Open

Wave 3 syncs the Cilium policies unenforced, with Hubble to see drops:
`.kiro/specs/wave3-*`.

- [ ] 16. Default-deny network policies, one namespace per PR, ingress then
      egress: mealie, immich, paperless, syncthing, theater, then keycloak,
      monitoring and argo (policies not written yet for the last three).
- [ ] 17. Kubernetes API authentication by Keycloak OIDC (Talos
      `AuthenticationConfiguration`, a ClusterRoleBinding from a Keycloak
      group); the admin certificate becomes break-glass only. One control
      plane at a time.
- [ ] 18. Then Headlamp with per-user OIDC tokens instead of its
      ServiceAccount.
- [ ] 19. Keycloak hardening in code: brute-force protection and lockout
      settings, direct-access grants off and read back by the PostSync Job
      (OTP for admins: task 26).
- [ ] 20. External Secrets Operator proof of concept on one app (Mealie);
      backend to choose: OpenBao with a static seal, Infisical, or Bitwarden
      Secrets Manager. SOPS stays the bootstrap store.
- [ ] 21. Phone toolkit: a reduced talosconfig (`os:operator`) for the
      phone, never the `os:admin` one.
- [ ] 22. Rotate the values once accepted as exposed (operator-only): the old
      Cloudflare user token, the NAS root password, the DNS registrar API key.
- [ ] 23. Scheduled, scoped pentest of the own IPs and domains: authenticated
      DAST, external port and TLS scans, an in-cluster assessment, a Keycloak
      review. Guardrails enforced technically (no AWS or NAS admin keys,
      locked backup versions); written rules of engagement; private report.
- [x] 26. Headlamp public at `headlamp.lilalala.com` behind Keycloak; the
      tailnet Ingress removed; UIs public, cluster APIs tailnet-only as the
      rule. [4.3, 4.6] (#538)
- [ ] 27. Argo CD client secret in its own sealed Secret, out of the
      chart-managed `argocd-secret` (an upgrade dropped the hand-added key
      and the login); smoke item 11 checks the SSO redirects and that
      Keycloak accepts the secret. [5.6]
