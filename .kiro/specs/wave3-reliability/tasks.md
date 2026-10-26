# Tasks: wave 3 reliability (runbooks and SLO refinements)

Each task is one PR or one recorded check. Requirement numbers in brackets. One topic per
PR; CI is the gate; merge with `scripts/pr-merge.sh`.

- [x] 1. Answer the design's open questions in `design.md` (read-only: repo, Prometheus,
      ntfy docs, the Renovate docs). [1.5, 3.2, 4.1, 5.1] Done in the PR of task 2.
- [x] 2. PR `test(alerting): a promtool test for every alert`: add the missing promtool
      tests (open question 7: none) and repo-policy rule `alert-tests`. [2.4, 2.5, 6.1]
      #514
- [x] 3. PR `feat(alerting): a runbook for every paging alert` (#509, adopted):
      `docs/runbooks/alerts/<AlertName>.md` and the index with the chart pages,
      `runbook_url` on every `action: human` rule, repo-policy rule `alert-runbooks` (also
      the chart rules of the `ntfy` lines of `routes.txt`), links from `docs/sre.md` and
      `docs/observability.md`. [1.1, 1.2, 1.3, 1.4, 1.6, 2.1, 2.2, 2.3, 2.5] #509
- [x] 4. PR `feat(alerting): the runbook link in every notification`: `X-Message` in
      `values.yaml` (no `X-Click`, open question 1); check on the phone with one test
      alert. [1.5] #520
- [x] 5. Run `scripts/slo-latency-thresholds.sh` (new, read-only) and record each app's
      p95 and threshold in the PR of task 6. [3.2] Every app 0.25 s (p95 0.065 to
      0.106 s, successful-but-slow share 0.02% to 0.53%) over the 3.2 days of probe data
      Prometheus holds; recorded in `docs/sre.md` (Latency) and the PR of task 6.
- [x] 6. PR `feat(slo): a latency SLO per app`: recording rules, thresholds,
      `SLOLatencyBudgetBurnSlow` (auto) and `SLOLatencyBudgetBurnSlowPersistent` (human)
      with promtool tests (fires, stays quiet under an availability burn, stays quiet when
      fast), runbook section, `routes.txt` line, overview panels, `docs/sre.md` and
      `docs/observability.md`. [3.1, 3.3, 3.4, 3.5, 3.6, 3.7, 6.1, 6.2, 6.3] #524
- [x] 7. PR `feat(slo): backup freshness SLO`: `routes/backup-slo.yaml`, `BackupNotFresh`
      with promtool tests (stale, suspended, fresh, a failed Job, kube-state-metrics
      absent), runbook section, `routes.txt` line, Data Protection panels, `docs/sre.md`
      RPO table and `docs/backups.md`. No inhibit rule: the expression leaves out a
      CronJob with a failed Job (design, Decisions). [4.1, 4.2, 4.3, 4.4, 4.5, 4.6, 6.1,
      6.2, 6.3] #531
- 8. Moved to the backlog: #744 (Hold Renovate on an app out of error budget).
- [x] 9. Live check, read-only: new series present per app and target, no new alert
      firing (the gate checks went with task 8). [3.3, 4.2] 2026-10-16 21:10Z:
      `slo:latency_budget_remaining:ratio_rate30d` for the 7 apps; the ntfy page of a
      synthetic alert ends with its runbook URL (17:10Z). `SLOLatencyBudgetBurnSlow`
      (`action: auto`, no page) fired for syncthing: the latency series was 4 hours old,
      so every window held the same 1.2% (0.7% failed probes, one near the 10 s
      timeout); the 2h window was 0, so it ends when the burst leaves the 6h window,
      well before the persistent page's day. 21:35Z, after #531: `slo:backup_fresh` for
      18 restic and 8 cnpg targets, none stale; `BackupNotFresh` neither pending nor
      firing.
- [x] 10. Tick this file and record the PR numbers. [all]
