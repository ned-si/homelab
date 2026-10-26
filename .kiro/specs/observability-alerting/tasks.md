# Tasks: observability-alerting

Requirement numbers in brackets. A living area spec: the history of the area,
no open tasks. New work is an issue on the board, and a change spec when it
needs one ([README](../README.md)).

## Done

- [x] 1. Probe public hostnames with blackbox-exporter. [1.1] (#258)
- [x] 2. Availability SLOs with burn-rate alerts; alert when one target stops
      reporting; show the share of the window with data. [1.1-1.3] (#259, #300, #452)
- [x] 3. Overview and Security dashboards; Overview as the start page. [5.2] (#260, #431)
- [x] 4. Watchdog heartbeat to a dead-man's switch, then healthchecks.io. [3.3] (#261, #283)
- [x] 5. Prometheus at 25Gi for 30 days of SLO data. [1.1] (#305)
- [x] 6. Warning and critical alerts to ntfy.sh; Argo CD alerts; general
      cluster alerts. [2.2] (#325, #330, #351)
- [x] 7. Scheduled workflow failures to ntfy. [3.2] (#343)
- [x] 8. SRE policy, error budgets and postmortems. [1.4] (#352)
- [x] 9. Node, Storage, Network, CI-CD, Usage, AWS, Data protection
      dashboards. [5.1] (#381, #392, #395, #386, #405, #429, #448)
- [x] 10. NAS exporter and alerts; LAN pings and inventory. (#383, #387, #397)
- [x] 11. CVE reports and their KEV/EPSS ranking. (#380, #453)
- [x] 12. Notify on symptoms only, one per root cause; scenario tests. [2.3] (#449, #454)
- [x] 13. Maintenance silence script. [4] (#450)
- [x] 14. Quiet hours 23:00-08:00 Europe/Zurich, Actions posts held until 08:00. [3.1, 3.2]
      (#460, #463)
- [x] 15. Page on read-only disks, Talos upgrades and delivery failures. [2.2] (#472)
- [x] 16. Keep `grafana.db` on a volume. [5.4] (#473, #475)
- [x] 17. Page only when a person has to act (`action` label). [2.1, 2.2] (#484)
- [x] 18. Homelab / Automation dashboard and its event feed. [5.3] (#486, #490, #493)

- [x] 22. metrics-server with verified kubelet TLS: kubelet serving
      certificates by CSR and kubelet-serving-cert-approver, applied one node
      at a time after the approver runs. [6.1-6.3] (#522)

## Moved to the backlog (2026-10-26)

Wave 3 is specced in `.kiro/specs/wave3-*`: a runbook for every alert,
latency and backup-freshness SLOs, Hubble relay and UI, Tetragon in observe
mode, and a log store trial. Not repeated here.

- 19. Moved to the backlog: #733 (Chaos experiments tied to SLOs).
- 20. Moved to the backlog: #734 (Wide-event observability trial).
- [x] 21. (#703, the Security dashboard row; the export reaches the log store through Vector's `kubernetes_logs` source) Tetragon events on the Security dashboard and in the log store,
      once both exist.
