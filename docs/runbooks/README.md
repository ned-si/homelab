# Runbooks

Task-oriented pages: preconditions, numbered steps with the commands and the
expected output, rollback. Pages for paging alerts are in
[alerts/](alerts/README.md).

| Runbook | When |
| --- | --- |
| [add-a-person.md](add-a-person.md) | Give someone access to the household's services, or take it away |
| [keycloak-otp.md](keycloak-otp.md) | Enroll or reset a Keycloak authenticator; break-glass into Keycloak |
| [grafana-break-glass.md](grafana-break-glass.md) | Log in to Grafana without Keycloak |
| [cold-start.md](cold-start.md) | Bring everything back after a power loss or a move |
| [node-power-cycle.md](node-power-cycle.md) | Hard-reset a node from the Turing Pi 2 BMC |
| [node-replacement.md](node-replacement.md) | Reflash a node and join it back |
| [wan-ip-change.md](wan-ip-change.md) | The ISP changed the public address |
| [netpol-enforcement.md](netpol-enforcement.md) | Switch default-deny on for a namespace, or break-glass out of it |
| [pv-selinux-label.md](pv-selinux-label.md) | Label an existing iSCSI volume for SELinux |
| [immich-upgrade.md](immich-upgrade.md) | Immich server and database upgrades |
| [arr-qbittorrent.md](arr-qbittorrent.md) | The *arr apps cannot reach qBittorrent |
| [subtitles.md](subtitles.md) | Subtitles keep switching themselves off |
| [nfs-hardening.md](nfs-hardening.md) | The open gap on the media NFS export |
| [paperless-postgres.md](paperless-postgres.md) | Moving Paperless from SQLite to PostgreSQL (an option, not done) |
