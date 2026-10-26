# Tasks: access-identity

Requirement numbers in brackets. A living area spec: the history of the area,
no open tasks. New work is an issue on the board, and a change spec when it
needs one ([README](../README.md)).

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

## Moved to the backlog (2026-10-26)

Wave 3 syncs the Cilium policies unenforced, with Hubble to see drops:
`.kiro/specs/wave3-*`.

- 16. Moved to the backlog: #709 (Enforce the CiliumNetworkPolicies, one namespace at a time).
- 17. Moved to the backlog: #711 (Kubernetes API authentication through Keycloak OIDC).
- 18. Moved to the backlog: #712 (Headlamp with per-user OIDC tokens).
- [x] 19. (#691) Keycloak hardening in code: brute-force protection and lockout
      settings, direct-access grants off and read back by the PostSync Job
      (OTP for admins: task 26).
- 20. Moved to the backlog: #713 (OpenBao as the issuer of cluster-owned secrets, through ESO).
- 21. Moved to the backlog: #716 (A reduced talosconfig for the phone).
- 22. Moved to the backlog: #717 (Rotate the values once accepted as exposed).
- 23. Moved to the backlog: #718 (A scheduled, scoped pentest of the own IPs and domains).
- [x] 26. Headlamp public at `headlamp.lilalala.com` behind Keycloak; the
      tailnet Ingress removed; UIs public, cluster APIs tailnet-only as the
      rule. [4.3, 4.6] (#538)
- [x] 27. Argo CD client secret in its own sealed Secret, out of the
      chart-managed `argocd-secret` (an upgrade dropped the hand-added key
      and the login); smoke item 11 checks the SSO redirects and that
      Keycloak accepts the secret. [5.6] (#562)
