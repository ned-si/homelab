# Tasks: wave 3 reliability (runbooks and SLO refinements)

Each task is one PR or one recorded check. Requirement numbers in brackets. One topic per
PR; CI is the gate; merge with `scripts/pr-merge.sh`.

- [x] 1. Answer the design's open questions in `design.md` (read-only: repo, Prometheus,
      ntfy docs, the Renovate docs). [1.5, 3.2, 4.1, 5.1] Done in the PR of task 2.
- [ ] 2. PR `test(alerting): a promtool test for every alert`: add the missing promtool
      tests (open question 7: none) and repo-policy rule `alert-tests`. [2.4, 2.5, 6.1]
- [ ] 3. PR `feat(alerting): a runbook for every paging alert` (#509, adopted):
      `docs/runbooks/alerts/<AlertName>.md` and the index with the chart pages,
      `runbook_url` on every `action: human` rule, repo-policy rule `alert-runbooks` (also
      the chart rules of the `ntfy` lines of `routes.txt`), links from `docs/sre.md` and
      `docs/observability.md`. [1.1, 1.2, 1.3, 1.4, 1.6, 2.1, 2.2, 2.3, 2.5]
- [ ] 4. PR `feat(alerting): the runbook link in every notification`: `X-Message` in
      `values.yaml` (no `X-Click`, open question 1); check on the phone with one test
      alert. [1.5]
- [ ] 5. Run `scripts/slo-latency-thresholds.sh` (new, read-only) and record each app's
      p95 and threshold in the PR of task 6. [3.2]
- [ ] 6. PR `feat(slo): a latency SLO per app`: recording rules, thresholds,
      `SLOLatencyBudgetBurnSlow` (auto) and `SLOLatencyBudgetBurnSlowPersistent` (human)
      with promtool tests (fires, stays quiet under an availability burn, stays quiet when
      fast), runbook section, `routes.txt` line, overview panels, `docs/sre.md` and
      `docs/observability.md`. [3.1, 3.3, 3.4, 3.5, 3.6, 3.7, 6.1, 6.2, 6.3]
- [ ] 7. PR `feat(slo): backup freshness SLO`: `routes/backup-slo.yaml`, `BackupNotFresh`
      with promtool tests (stale, suspended, fresh, inhibited case in an Alertmanager
      scenario), the inhibit rule, runbook section, `routes.txt` line, Data Protection
      panels, `docs/sre.md` RPO table and `docs/backups.md`. [4.1, 4.2, 4.3, 4.4, 4.5, 4.6,
      6.1, 6.2, 6.3]
- [ ] 8. PR `ci: hold Renovate on an app out of budget and still failing`:
      `SLOAutomergePause` (promtool tests), the `ntfy-guard` route and its `routes.txt`
      line, `scripts/ci/error-budget-gate.sh` and its bash test, `ci/slo-app-paths.txt`
      and repo-policy rule `slo-app-paths`, job `error-budget` in `ci.yaml`,
      `error-budget-recheck.yaml`, `docs/sre.md`. Skip with a recorded reason per the
      design's error handling if the guard topic cannot carry the state. [5.1, 5.2, 5.3,
      5.4, 5.5, 5.6, 6.1, 6.3]
- [ ] 9. Live check, read-only: new series present per app and target, no new alert
      firing, gate dry run prints "no app paused", `gh workflow view
      error-budget-recheck.yaml` enabled. [3.3, 4.2, 5.2]
- [ ] 10. Tick this file and record the PR numbers. [all]
