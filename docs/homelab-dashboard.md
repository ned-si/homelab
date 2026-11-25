# Homelab dashboard

`https://homelab.nedsi.io/` is the homelab's public dashboard: live
availability per app against the 99.5% target, certificates, cluster,
security and project figures. It is
first-party Go code in [`dashboard/`](../dashboard/), deployed by the
Application `homelab-dashboard` from
[`apps/homelab-dashboard/`](../apps/homelab-dashboard/). The design and its
decisions are in [spec homelab-dashboard](../.kiro/specs/homelab-dashboard/design.md).

## How it works

One binary, `homelab-dashboard`, one image, two Deployments in namespace
`homelab-dashboard`:

```text
Prometheus ──┐                                      ┌──> web :8080 ──> Gateway ──> reader
GitHub API ──┴──> collector ── signed POST :9465 ───┤    (public key only,
                  (push key, GitHub token, egress)  │     no token, no egress)
                                                    └──> every web pod (headless Service)
```

| Role | Deployment | Holds | Reaches |
| --- | --- | --- | --- |
| `collect` | `homelab-dashboard-collector` | Secret `homelab-dashboard-push` (`private-key`), Secret `homelab-dashboard-github` (`token`) | Prometheus 9090, the web pods' 9465, `world` 443 (GitHub) |
| `web` | `homelab-dashboard-web` | ConfigMap `homelab-dashboard-push-pubkey` (`public-keys`) | nothing but cluster DNS |

- Every 60 s the collector reads Prometheus (GitHub on a slower cadence),
  builds the snapshot, validates it against the embedded schema and the
  compiled allow-list of shown apps, signs it with Ed25519 and posts it to
  `POST /v1/snapshot` on port 9465 of every web pod, through the headless
  Service `homelab-dashboard-web-push`.
- The web pod checks the size, the signature, the freshness (at most 5 min
  old, 1 min ahead) and the schema, keeps the last good snapshot in memory
  and renders the page on every request with `html/template`.
- Port 8080 answers only `GET` and `HEAD` on `/`, `/snapshot.json` and
  `/assets/dashboard.<hash>.css`; anything else is `404`, any other method
  `405`. Port 9465 is in no HTTPRoute, port 9464 (`/metrics`, `/healthz`,
  `/readyz`) neither.
- Neither pod mounts a ServiceAccount token
  (`automountServiceAccountToken: false`). Both run as UID 65532 with a
  read-only root file system, all capabilities dropped and the
  `RuntimeDefault` seccomp profile. The namespace is default-deny
  (`infrastructure/network-policies/90-enforcement.yaml`), the allow-list is
  [`56-homelab-dashboard.yaml`](../infrastructure/network-policies/56-homelab-dashboard.yaml).
- The HTTPRoute `homelab-dashboard/homelab-dashboard` sets the same security
  headers and CSP as the other sites; the server sets them too.
  `tests/test_security_controls.py` keeps both CSPs equal. Plain HTTP and
  `blog.nedsi.io/homelab/` are `301`s served by the website's nginx
  ([networking.md](networking.md#nedsiio)).

## Operate

```sh
kubectl -n homelab-dashboard get pods
curl -sI https://homelab.nedsi.io/ | head -1
curl -s https://homelab.nedsi.io/snapshot.json | jq -r .generated_at
```

Expected: two pods `Running`, `HTTP/1.1 200 OK`, a time less than two
minutes old.

| Task | How |
| --- | --- |
| Logs | `kubectl -n homelab-dashboard logs deploy/homelab-dashboard-collector --since=1h`; the web role logs one JSON line per request, also in SigNoz |
| Force a push | `kubectl -n homelab-dashboard rollout restart deploy/homelab-dashboard-collector` |
| Stale figures | the alert [HomelabDashboardSnapshotStale](runbooks/alerts/HomelabDashboardSnapshotStale.md) (no accepted push for 48 h) |
| Probe | `probe_success{app="homelab"}`, job `blackbox-public`, in the SLO like every user-facing app ([sre.md](sre.md)) |
| Deploy-time check | the PostSync smoke Job checks the Service, then `https://homelab.nedsi.io/` through the Gateway: `200`, the headers, `405`, `404` |

### Rotate the push key

The web pod accepts any of the one or two public keys in
`apps/homelab-dashboard/push-pubkey.yaml` and re-reads the file every 30 s,
so a rotation needs no release. One merge each:

1. Generate a new key pair (`openssl genpkey -algorithm ed25519`) and add
   its public key (`openssl pkey -pubout`) as a second PEM block.
2. Reseal the private key into `apps/secrets/homelab-dashboard-push.sops.yaml`
   (key `private-key`), as in its `.example`.
3. Once `homelab_dashboard_push_total{result="accepted"}` grows again,
   drop the old public key.

The rotation table, with the GitHub token, is in
[secrets.md](secrets.md#rotating-a-credential).

## Build, release and verify

Local checks, from the repository root, with Go and golangci-lint on `PATH`:

```sh
scripts/ci/dashboard-check.sh --all
```

Expected: every step `==` with no `FAIL`, exit 0. It runs `go mod verify`,
`go mod tidy -diff`, golangci-lint (`dashboard/.golangci.yaml`), `go vet`,
`govulncheck`, `go test -race` with the golden pages and `go build`. The same
script is the `dashboard` job of `ci` ([testing.md](testing.md#2-static-ci)).

A dry run against the live Prometheus prints the snapshot instead of pushing:

```sh
kubectl -n monitoring port-forward svc/kube-prometheus-stack-prometheus 9090 &
cd dashboard && go run ./cmd/homelab-dashboard collect --once --dry-run \
  --prometheus-url http://127.0.0.1:9090 --github-token-file /nonexistent | jq .
kill %1
```

Expected: the snapshot as JSON on stdout (a missing token file means
anonymous GitHub calls), logs on stderr.

Release: a merge to `main` that touches `dashboard/` runs
`.github/workflows/dashboard-publish.yaml`. It smoke-tests the image, builds
`linux/arm64` and `linux/amd64` with an SBOM and SLSA provenance, attests the
provenance, signs the index keyless with cosign, tags it `main` and notifies
ntfy on failure. Before signing, it checks with `gh attestation verify`
that the provenance names `dashboard-publish.yaml` on `main` and a
GitHub-hosted runner; `site-publish` does the same for the site image.
Renovate then opens the digest bump of `apps/homelab-dashboard/` (group
`homelab-dashboard`), which automerges on green CI. Kyverno's
`verify-own-images` checks the signature and the provenance in the cluster.

Verify the running image:

```sh
img=$(kubectl -n homelab-dashboard get deploy homelab-dashboard-web \
  -o jsonpath='{.spec.template.spec.containers[0].image}')
cosign verify \
  --certificate-identity https://github.com/ned-si/homelab/.github/workflows/dashboard-publish.yaml@refs/heads/main \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com \
  "ghcr.io/ned-si/homelab-dashboard@${img#*@}"
gh attestation verify "oci://ghcr.io/ned-si/homelab-dashboard@${img#*@}" --owner ned-si
```

Expected: cosign prints the verified signature payload; `gh` prints
`Verification succeeded!`.

## Cards

Every figure is live: the collector refreshes each block every 60 s, the
project block every 15 min. A card whose block is more than 5 min older than
the snapshot (60 min for the project) says "Figures from <time>".

Every time window is rolling and ends now: at the cycle, at the last
evaluation of the recording rule it reads, or at the project block's last
GitHub refresh. None is a calendar month, week or day, except the daily
bars, which are Zurich days from midnight to midnight (23 and 25 hours on
the days summer time starts and ends), the last one from midnight to now
([Requirement 2.8](../.kiro/specs/homelab-dashboard/requirements.md#requirement-2-same-figures-same-privacy-rules)).

| Card | Shows | Source |
| --- | --- | --- |
| Availability, one per shown app | State ("Up", "Down", "No data"), the rolling 30 days, the error budget left, 30 daily bars, the last one today so far | `probe_success` of the app's probes, averaged over each day for the bars; `slo:availability:ratio_rate30d`, `slo:error_budget_remaining:ratio_rate30d` ([sre.md](sre.md)) |
| Cluster | Per node and for the NAS: utilisation, saturation, errors (USE); at the Gateway: requests per second, `5xx` share and p95 over a rolling 5 min (RED); Argo CD Synced and Healthy, restarts over a rolling 24 h, volumes, versions | node-exporter, kube-state-metrics, `truenas_*`, Envoy, `argocd_app_info`, kubelet volume stats, all summed in PromQL |
| Project | The four DORA metrics with their band and the overall level (the lowest of the four bands, "No data" when one is missing), the rework rate without a band, Renovate's share, the median `ci` run, the last five `ci` runs on `main` | GitHub, the `action: human` alerts ([DORA figures](#dora-figures)) |
| Supply chain | Per first-party image (`homelab-dashboard`, `homelab-site`): "Build L2" when Kyverno verified its provenance on every Pod with a report, "Verified", "Not verified" or "No data", and the builder | `kyverno_policyreport_result_info{policy="verify-own-images"}` from kube-state-metrics, joined with `kube_pod_container_info` by Pod and counted per image ([SLSA level](#slsa-level)) |
| Security | Per signal: the count of the rolling 24 h and 7 days, its share of the requests or sign-ins, and the 7 days in 28 six-hour bars. Signals: unknown host or path (no route, and `404` from the static sites), refused by an app (`401` and `403`, the `403` part in the detail), method not allowed (`405`), failed sign-ins, deployments blocked by policy (Kyverno and Pod Security in enforce mode), ingress packets dropped from the internet, runtime detections. Under the 4xx tiles, the `4xx` the Gateway answered itself, which no tile can attribute | Envoy's counters on the shared Gateway, `keycloak_user_events_total`, `apiserver_admission_webhook_rejection_count`, `pod_security_evaluations_total`, `hubble_drop_total` from `reserved:world`, the `Runtime*` alerts; each one sum over the cluster |
| Certificates | Days left per shown certificate | `probe_ssl_earliest_cert_expiry` of the public probes |

The page shows the cards in this order, then "Coming later". From the
Cluster card down, every figure is a stat tile: a label above its value,
the status colour on the value or, for a word, as a left border. Every
percentage has two decimals: the snapshot keeps full precision and the page
rounds once, half to even; the status colours read the raw values.

Our own traffic stays out of the Gateway's `4xx` and `405` figures: public
probes expect only `2xx` or `3xx` (repo-policy `public-probe-codes`), and
the smoke hooks send their deliberate `404` and `POST` to the Service. The
weekly `dast` scan and the quarterly pentest still cross the Gateway from
GitHub's runners, which Envoy cannot tell apart, so the Gateway tiles say
so.

The shown apps are Immich, Mealie, Paperless-ngx, Plex, Syncthing,
Keycloak, Observability (Grafana, SigNoz, Prometheus and Alertmanager), the
landing page, the blog and this dashboard. An app with fewer than 30 days of
probes shows "since <date>" in grey, with no status word and no budget.
Adding an app is a change to `dashboard/internal/snapshot/shown.go` and a
release.

## SLSA level

Both first-party images are at SLSA v1.0 Build L2: GitHub's
`actions/attest-build-provenance` signs the provenance with the workflow's
OIDC identity, in the job that builds, on a GitHub-hosted runner. Not L3:
the build steps run in that same job and could ask for the same token.
L3 needs the build in a reusable workflow, a change of signing identity
for Kyverno, `ci/image-signers.yaml` and the inventory; it is out of scope.
The level is compiled in `dashboard/internal/snapshot/shown.go`; the page
shows it only when Kyverno verified the provenance, and the publishing
workflows fail when the provenance stops matching. The README badge states
the same level
([design](../.kiro/specs/homelab-dashboard/design.md#which-slsa-build-level)).

## Privacy rules

- Shown apps and certificates are compiled allow-lists; a test fails when a
  download tool (`sonarr` and the rest) is added.
- Never household energy consumption; solar production is the only Home
  Assistant value the page may show.
- Cluster figures are aggregated in PromQL: the collector never receives a
  namespace, pod or volume name. The incident count reads the paging
  alerts' labels to tell firings apart; none reaches the snapshot.
- The security card shows only cluster-wide counts by category: no
  address, path, route, user, rule or alert name. It shows no brute-force
  lockout count: Keycloak locks existing accounts only, so the count would
  tell a stranger which usernames exist.
- The access log keeps time, method, path, status, bytes and duration: no
  client address, user agent, referrer or query string.

## DORA figures

The project block of `snapshot.json` carries the four DORA metrics and the
rework rate over the rolling 30 days ending at the fetch, defined so anyone
can recount them from the repository
([Requirement 10](../.kiro/specs/homelab-dashboard/requirements.md#requirement-10-project-card-dora-and-ci)):

| Metric | Keys | Counted as |
| --- | --- | --- |
| Deployment frequency | `deploys_30d` | Pull requests merged into `main` |
| Lead time for changes | `lead_time_seconds`, `lead_time_count` | Median from a pull request's creation to the first `argocd/<application>` commit status `success` on its merge commit within 24 h of the merge; the merge itself for a change outside `deploy/` and `clusters/` |
| Change failure rate | `failed_changes_30d`, `change_failure_rate` | Rollbacks (label `auto-rollback`, or a title starting with "revert") and fix forwards (label `fix-forward`, [sre.md](sre.md#fix-forward)) over the deploys |
| Time to restore | `incidents_30d`, `restore_seconds` | Median duration of the incidents that started in the window and ended: continuous firings of `action: human` alerts, and rollbacks from the reverted merge to the revert's sync; overlapping ones count once. A firing already going on when the window starts, and a rollback of a change merged before it, are left out |
| Rework rate | `rework.count`, `rework.deploys`, `rework.rate` | Rollbacks and fix forwards, plus the merges that change `deploy/` or `clusters/` with a `fix:`, `fix(<scope>):` or `fix!:` title merged during an incident or in the 24 h after it ends, each pull request once, over the deploys. DORA added it in 2024; it has no band, because the 2023 clusters the bands come from predate it |

They need the GitHub token (GraphQL), as does the median `ci` run (every
successful run of the window, listed in 24-hour slices). Without the token
they keep the value of the last refresh with it for an hour, then show
"No data". Recount them for the window of the live snapshot:

```sh
kubectl -n monitoring port-forward svc/kube-prometheus-stack-prometheus 9090 &
curl -s https://homelab.nedsi.io/snapshot.json >/tmp/snapshot.json
scripts/dashboard-dora-check.sh --compare /tmp/snapshot.json --prometheus http://localhost:9090
```

Expected: one `ok` line per figure, then `dashboard-dora-check: equal
within one pull request and one minute`.

## Status colours

Every figure's colour is a function in `dashboard/internal/web/status.go`,
tested on each boundary, and every colour has its word next to it.
Availability over 30 days is `ok` with more than 25% of the error budget
left, `warn` from 0% to 25%, `bad` below 0%. One day is `ok` from 99.5%,
`warn` from 96.25%, `bad` below. A certificate is "Valid" above 21 days,
"Renewal late" from 7 to 21, "Expiring" below 7. The cluster figures read
"OK", "Warning" or "Critical"; where an alert exists, its threshold is the
card's. A security signal where one event is worth a look reads "None"
or "Seen"; the others read "Usual", or "Above usual" when the 24 h count
is above 20 and three times the daily mean of the 6 days before. No
security figure is red: the alerts page, the card counts. An image's
provenance reads "Verified" in green or "Not verified" in amber. The DORA
metrics show their band: "Elite" and "High" in green,
"Medium" in amber, "Low" in red. The full table is in the
[design](../.kiro/specs/homelab-dashboard/design.md#status-colours).

## Why it is like this

- **A Go app, not a script.** One static binary on a distroless base,
  `html/template`'s escaping for a public page, built, tested, signed and
  versioned like the rest. Rejected: the nightly Python publisher in a
  ConfigMap that it replaced.
- **A signed push.** The public pod gets live figures with no egress, no
  token and no Kubernetes rights; it holds only a public key, which forges
  nothing. Rejected: a ConfigMap the collector patches (a Role, an API write
  a minute), the web pod pulling (egress on the public pod), HMAC (a shared
  secret on the public pod).
- **Its own host.** `homelab.nedsi.io` gets its own route, certificate and
  CSP and shares no path with the blog's nginx. Rejected: a path under
  `blog.nedsi.io` or `nedsi.io`.
