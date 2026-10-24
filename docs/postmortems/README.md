# Postmortems

One file per incident, newest first. When one is written and what it holds:
[sre.md](../sre.md#postmortems). Template: [template.md](template.md).

| Date | Incident | Cause |
| --- | --- | --- |
| 2026-10-23 | [Every public hostname down after the Cilium 1.20.4 update](2026-10-23-gateway-cilium-xds.md) | a Helm-owned `envoy-xds-mode: ads` survived the upgrade; the new Envoy bootstrap asked for separate streams, so the Gateway had no listeners |
| 2026-10-15 | [keycloak-db crash-loops on the CNPG minimal image](2026-10-15-keycloak-db-image.md) | the minimal image has no `en_US.utf8` locale, which the recovered data dir needs |
| 2026-10-15 | [LAN outage, cluster lost its storage](2026-10-15-basement-switch.md) | the unmanaged switch that carries the nodes and the NAS dropped its links |
| 2026-10-10 | [House power loss](2026-10-10-power-loss.md) | about 30 minutes without mains power; no UPS |
