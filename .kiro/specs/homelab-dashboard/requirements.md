---
kind: change
status: done
created: 2026-11-20
closed: 2026-11-24
issue: 1554
---
# Requirements: homelab-dashboard

## Introduction

The public dashboard at `https://blog.nedsi.io/homelab/` (public-website
task 7, #1550 and #1552) is a Python script in a ConfigMap, run by a
CronJob, whose HTML fragment nginx includes into a Hugo page with a
server-side include. It works, but it is a script, not software: no
build, no version, no signature, no metrics of its own.

This spec replaces it with a first-party app, `homelab-dashboard`, written
in Go and built and released like production software. It keeps the
security boundary that is the point of the page: the part that answers the
internet holds no credential and reaches nothing. It also keeps every
privacy rule of the public-website spec. The app is the project's
showcase: spec first, tested, signed, observable, rolled out next to the
script it replaces and switched over with a revert as the rollback.

The operator's decisions of 2026-11-20, recorded after the first spec
merged (#1556):

1. **Look**: a real observability dashboard. A grid of panels, big
   numbers with units, status colours against the 99.5% target,
   server-rendered inline SVG charts, the site's dark palette, responsive;
   no JavaScript and the same CSP. Golden HTML tests and a rendered
   screenshot check in CI.
2. **Address**: the dashboard gets its own host, `https://homelab.nedsi.io/`
   (DNS only, its own HTTPRoute and certificate, the record created by
   external-dns). `blog.nedsi.io/homelab/` redirects there permanently, and
   the Homelab links on the blog, the landing page and the app point there.
3. **Order**: implementation starts right after this amendment, tasks 1-3
   first; the public host, the redirect and the links come on a weekday
   in daytime with the operator.

The operator's decisions of 2026-11-23 (the redesign, tasks 8-15),
which replace the finished-day rule of 2026-11-20:

1. **Availability is live**: each app's current up or down state from
   its probes, its availability over the rolling 30 days ending now, its
   error budget and 30 daily bars, today's included.
2. **Near real time everywhere**: the cluster's USE and RED figures
   follow the collector's minute; no figure waits for a finished day.
3. **Cards**: availability for Immich, Mealie, Paperless-ngx, Plex,
   Syncthing, Keycloak, Observability (Grafana, SigNoz, Prometheus and
   Alertmanager), the landing page, the blog and the dashboard itself;
   Vault or OpenBao later. New cards: certificate validity; Cluster (USE
   for the nodes and the NAS, RED at the Gateway, Argo CD, pod restarts,
   volumes); Project (the four DORA metrics and the last five `ci` runs
   on `main`).
4. **Never household energy consumption.** Solar production stays the
   only Home Assistant value the page may show.
5. **Every change a generic rule**: thresholds, bands and lists are
   compiled rules with tests, not per-figure exceptions.

The operator's decision of 2026-11-24 (task 16): a Security card, with
near-real-time counts and a 24 h / 7 d sparkline, generic rules and
nothing that helps an attacker: no address, no path beyond the generic
"scanner paths" category, no rule name. It uses only data that exists
today; canary tokens are a separate spec, next month (#1618). No
brute-force lockout count: Keycloak locks existing accounts only, so it
would tell a stranger which usernames exist; failed sign-ins are shown
as a count and a sparkline instead (2026-11-24).

Non-goals are listed under [Out of scope](#out-of-scope).

## Glossary

- **App**: `homelab-dashboard`, one Go module in `dashboard/`, one binary,
  one image `ghcr.io/ned-si/homelab-dashboard`, two roles.
- **Collector**: the backend role. It runs in the cluster with read-only
  access to Prometheus and the public GitHub API, computes the public
  figures and pushes a signed snapshot to the web role every minute.
- **Web**: the frontend role that answers `https://homelab.nedsi.io/`.
  It accepts signed snapshots on an internal port, keeps the last good one
  in memory and renders the page, the snapshot and its static assets.
- **Snapshot**: `snapshot.json`, the public figures as one JSON document
  that validates against the app's JSON Schema.
- **Public figures**, **shown apps**, **personal data**: as defined in the
  public-website spec ([requirements](../public-website/requirements.md#glossary),
  [design, Public figures](../public-website/design.md#public-figures)).
  From the redesign every figure is live: refreshed at most every minute
  (GitHub figures every 15 minutes), none waits for a finished day
  ([design, Freshness](design.md#freshness)). The figures of the
  redesign are listed in [design, The snapshot](design.md#the-snapshot).
- **Card**: one panel of the page grid. An **availability card** shows
  one shown app; the **certificates**, **cluster**, **security** and
  **project** cards are the other panels.
- **Security signal**: one count on the security card, from the compiled
  list of [design, Security signals](design.md#security-signals-task-16),
  each a sum over the whole cluster.
- **DORA metrics**: deployment frequency, lead time for changes, change
  failure rate and time to restore, as defined for this repository in
  [Requirement 10](#requirement-10-project-card-dora-and-ci); each falls
  in a **DORA band** (`elite`, `high`, `medium`, `low`).
- **Publisher**: today's implementation, `apps/website/publisher/` and the
  `/homelab/` server-side include in `apps/website/nginx.conf`.
- **Status**: how a figure compares with its threshold: `ok`, `warn`,
  `bad` or `none` (no data). For availability the threshold is the 99.5%
  target (met, at risk, missed); every other figure has its own compiled
  thresholds. The rules are in
  [design, Status colours](design.md#status-colours).
- **Switch-over**: tasks 4 and 5. Task 4 puts the web role live on
  `homelab.nedsi.io`; task 5 turns `blog.nedsi.io/homelab/` into a
  permanent redirect there and points the Homelab links at it.

## Requirement 1: Two roles, one boundary

**User story:** As the operator, I want the public part of the dashboard to
know nothing and reach nothing, so a flaw in it exposes no internal
service or credential.

1. THE web role SHALL run with no ServiceAccount token, no Secret, no
   egress (enforced Cilium policy) and ingress only from the shared
   Gateway and the PostSync smoke Job on its public port 8080, from the
   collector on its push port 9465, and from Prometheus and the kubelet on
   its metrics port.
2. THE web role SHALL serve only the page, the snapshot and the assets
   compiled into the binary and SHALL make no outbound connection. On its
   public port it SHALL accept no input other than the method, the path
   and `If-None-Match`; on its push port only a snapshot signed by the
   collector.
3. THE collector SHALL have no route from the Gateway and no listener other
   than its metrics port; egress only to the Prometheus Service, the web
   role's push port and TCP 443 outside the cluster (`world`, for
   `api.github.com`; Cilium FQDN rules would route all DNS through its
   proxy).
4. NEITHER role SHALL hold a ServiceAccount token or any Kubernetes right.
5. THE only thing passed from the collector to the web role SHALL be the
   snapshot, pushed to the push port and signed with Ed25519. THE web role
   SHALL hold only the public key and SHALL accept a push only when the
   signature verifies, `generated_at` is newer than the current
   snapshot's, at most 5 minutes old and at most 1 minute in the future,
   and the document passes 2.6.

## Requirement 2: Same figures, same privacy rules

**User story:** As a reader, I want to see that the homelab runs, without
learning anything that helps an attacker or shows who is home.

1. THE snapshot SHALL hold only the figures listed in
   [design, The snapshot](design.md#the-snapshot), plus a
   `schema_version`. "Pull requests merged" SHALL count the pull requests
   merged into `main` in the rolling 30 days ending at the collection.
2. EVERY figure SHALL be near real time: the availability, certificate,
   cluster and security blocks refreshed every collector cycle (60 s),
   the project block every 15 minutes with the GitHub token. No figure
   SHALL wait for
   a finished day. Availability per shown app SHALL be its current state
   (up or down, from its latest probes), its availability and error
   budget over the rolling 30 days ending now, and 30 daily values, the
   last one today from Zurich midnight to now (operator, 2026-11-23).
3. THE shown apps and the shown certificates SHALL be allow-lists
   compiled into the binary; the *arr apps, qBittorrent, the indexers and
   the rest of the download tooling SHALL never be queried by name,
   written or rendered, and a unit test SHALL fail if one is added.
4. AN app with fewer than 30 days of data SHALL show its figure with
   "since <first day>" in the neutral colour, with no status word ("Met",
   "At risk", "Missed") and no error budget.
5. Solar production MAY be added later (production only). Household
   energy consumption SHALL never be collected or shown (operator,
   2026-11-23), and neither SHALL grid import and export, battery,
   charging, presence or any other Home Assistant value.
6. THE web role SHALL re-validate the snapshot it loads (schema, ranges,
   the compiled allow-lists) and SHALL refuse a document that fails,
   keeping the last good one.
7. CLUSTER figures SHALL be per node (by node name), for the NAS, for
   the Gateway as a whole or summed over the cluster; no figure SHALL
   name a namespace, a pod, a volume or an app outside the shown apps.

## Requirement 3: The page

**User story:** As a reader, I want a dashboard I can read at a glance,
in the look of the rest of the site.

1. THE page SHALL be served at the root of its own host,
   `https://homelab.nedsi.io/`, and SHALL carry the site's header,
   navigation bar (Home `https://nedsi.io/`, Blog `https://blog.nedsi.io/`,
   Homelab `https://homelab.nedsi.io/`, About `https://blog.nedsi.io/about/`)
   and footer, the intro text and the "Coming later" panels (solar, home
   automation).
2. THE page SHALL be server-rendered with Go `html/template`, with no
   JavaScript, no inline style, no form, no iframe, no web font and no
   third-party resource; every chart is inline SVG built from numbers.
3. EVERY response SHALL carry the headers and the CSP of the public-website
   spec (Requirement 3.2 there), set by the web role itself and by the
   HTTPRoute.
4. THE web role SHALL answer only `GET` and `HEAD` (any other method `405`)
   on `/`, `/snapshot.json` and its stylesheet, and `404` with the same
   headers for any other path.
5. WHEN the web role holds no valid snapshot, THE page SHALL show "No
   figures yet"; WHEN `generated_at` is more than 5 minutes old, THE page
   SHALL say from when; WHEN one block's `as_of` is more than 5 minutes
   older than `generated_at` (an hour for the project block), THAT card
   SHALL say from when its figures are.
6. THE web role's access log SHALL keep `time`, `method`, `path`, `status`,
   `bytes` and the duration, and SHALL NOT keep the client address, the
   user agent, the referrer or the query string.
7. THE page SHALL be a grid of cards: one availability card per shown
   app, the certificates card, the cluster card, the security card, the
   project card and the "Coming later" panels, each figure a large
   number with its unit.
   EVERY row SHALL be filled, whatever the number of cards, at a phone
   and a desktop width.
8. EACH availability card SHALL show the app's current state ("Up",
   "Down" or "No data"), its 30-day availability with its status in
   colour and in words, its error budget left as a meter, and its 30
   daily values as a bar chart, today's bar last and marked as today so
   far, each bar coloured by that day's status. Colour SHALL never be the
   only carrier of a status, and every text and status colour SHALL have
   a contrast of at least 4.5:1 against its background.
9. THE page SHALL use the site's dark palette and SHALL read without
   horizontal scrolling from 320 px wide up to a desktop screen.

## Requirement 4: Built and released like production software

**User story:** As the operator, I want the app's image to be traceable to
a reviewed commit, so the cluster runs only what CI built and signed.

1. EVERY pull request touching `dashboard/` SHALL run, inside the required
   `ci` check: `golangci-lint run` (the configuration of the design's
   [Code style](design.md#code-style), Google Go Style Guide), `go vet`,
   `govulncheck`, `go mod verify`, and `go test -race` with unit and
   golden HTML tests; any finding fails `ci`.
2. A merge to `main` touching `dashboard/` SHALL build one image for
   `linux/arm64` and `linux/amd64`, on a distroless base, running as
   non-root, and push it to `ghcr.io/ned-si/homelab-dashboard`.
3. THE image SHALL carry an SBOM and SLSA build provenance, and SHALL be
   signed keyless with cosign by the publishing workflow's identity before
   it is tagged `main`.
4. THE cluster SHALL run the image by digest; Kyverno (spec
   image-provenance) SHALL verify its signature, and the signer list SHALL
   name its identity.
5. Renovate SHALL update the Go modules, the Go toolchain, the base and
   builder images and the deployed digest; every GitHub Action SHALL be
   pinned to a SHA and every tool to a version with a checksum.
6. THE binary SHALL report its version (the git commit) with `version`, in
   its first log line and in a `build_info` metric.
7. EVERY pull request touching `dashboard/` SHALL render the page in a
   pinned headless browser at a phone width and the desktop widths of
   4:3, 16:10 and 16:9 screens, inside `ci`; a browser error, a blocked
   resource, a CSP violation, a card off the column grid or a lone card
   stretched across its row fails `ci`, and the screenshots are attached
   to the run.

## Requirement 5: Observable

**User story:** As the operator, I want to be told when the dashboard stops
updating, and nothing else.

1. BOTH roles SHALL expose Prometheus metrics on an internal port:
   collector runs by block and result, errors by source, run duration,
   pushes by result, whether the GitHub token is accepted; web the age of
   the snapshot it serves and of each of its blocks, refused pushes by
   reason and requests by status.
2. AN alert SHALL page (`action: human`) when the snapshot served is older
   than 48 hours, with a runbook.
3. BOTH roles SHALL log JSON lines (`log/slog`) to stdout, which Vector
   already ships to SigNoz.

## Requirement 6: Migration without a gap

**User story:** As the operator, I want to switch to the app only once it
shows the same figures, and to go back with a revert.

1. THE app SHALL first run next to the publisher, with no public route,
   and a dry run of its collector at the end of the publisher's `covers`
   day SHALL be compared with the publisher's `figures.json` by a script.
2. THE switch-over SHALL happen only after the comparison has matched for
   three consecutive nights, on a weekday in daytime with the operator.
3. Reverting the redirect PR (task 5) SHALL give the publisher's page back
   at `blog.nedsi.io/homelab/` with no other step; reverting the host PR
   (task 4) SHALL take `homelab.nedsi.io` off the Gateway.
4. `publisher.py`, its CronJob, ConfigMaps, Role and network policy, the
   SSI location in `nginx.conf`, the Hugo `homelab` page and layout and the
   publisher tests SHALL be deleted only after the redirect has been live
   for one daily block.

## Requirement 7: Its own address

**User story:** As a reader, I want the dashboard at one short address,
and every old link to still work.

1. THE dashboard SHALL be served at `https://homelab.nedsi.io/` through
   the shared Gateway, with its own HTTPRoute, a certificate issued by
   cert-manager and an A record created by external-dns, DNS only (no
   Cloudflare proxy). `http://homelab.nedsi.io/<path>` SHALL answer `301`
   to `https://homelab.nedsi.io/<path>`.
2. `https://blog.nedsi.io/homelab`, `/homelab/` and `/homelab/<path>`
   SHALL answer `301` (permanent) to `https://homelab.nedsi.io/` and
   `https://homelab.nedsi.io/<path>`.
3. THE Homelab link of the navigation bar SHALL point to
   `https://homelab.nedsi.io/` on the blog, the landing page and the app,
   and so SHALL the landing page's dashboard button.
4. `homelab.nedsi.io` SHALL be in the pentest scope (and so the `dast`
   targets) and in the blackbox probe list as app `homelab`, with the
   99.5% SLO and a row in the user-facing app table of `docs/sre.md`.

## Requirement 8: A probe behind every availability card

**User story:** As a reader, I want every availability card to measure
what a user of that app gets, by one rule for all of them.

1. EVERY shown app SHALL have blackbox probes whose `app` label is the
   app's `SLOApp`, and the SLO recording rules of
   `platform/kube-prometheus-stack/routes/slo.yaml` SHALL cover it.
2. Plex SHALL be probed on `https://watch.lilalala.com/identity` (no
   login needed), app `watch`, with the 99.5% SLO, its alerts and a row
   in the user-facing app table of `docs/sre.md`.
3. Observability SHALL be one shown app, `observability`, whose probe
   result at each instant is the mean of the probes of Grafana and SigNoz
   (public) and of Prometheus and Alertmanager (in-cluster `/-/ready`).
   It SHALL get recording rules and no burn alert, so it pages through
   none of the SLO alerts (Grafana carries no SLO, `docs/sre.md`).
4. THE dashboard's own card SHALL use the probe of task 4 (app
   `homelab`); until it exists the card shows "No data".
5. Vault or OpenBao SHALL get a card when it is deployed, by adding it to
   the shown apps with its probe; nothing is reserved before.

## Requirement 9: Certificates card

**User story:** As a reader, I want to see that the public certificates
renew on time.

1. THE certificates card SHALL show, for each shown certificate, the
   whole days until the certificate served on its public names expires,
   as seen by the public probes (`probe_ssl_earliest_cert_expiry`,
   lowest over the certificate's names).
2. THE shown certificates SHALL be `*.lilalala.com`, `nedsi.io` (the
   landing page and the blog) and, from task 4, `homelab.nedsi.io`.
3. THE status SHALL be `ok` above 21 days, `warn` from 7 to 21 days
   (cert-manager renews at 30 days left, so this is a late renewal), `bad`
   below 7 days and `none` without a probe result, with the words
   "Valid", "Renewal late", "Expiring" and "No data".

## Requirement 10: Project card, DORA and CI

**User story:** As a reader, I want the project's delivery measured by
the four DORA metrics, each defined so anyone can recount it from the
repository.

Over the rolling 30 days ending at the collection (the window of 2.1):

1. **Deployment frequency** SHALL be the pull requests merged into `main`
   (`main` is production: Argo CD deploys every merge), shown as the
   count and the mean per day.
2. **Lead time for changes** SHALL be the median, over the deploying
   merges, of the time from the pull request's creation to its merge
   commit being synced. A deploying merge is one whose pull request
   changes a file under `deploy/` or `clusters/`; it is synced at the
   first `argocd/<application>` commit status `success` on its merge
   commit. A merge that changes neither directory deploys nothing new:
   its lead time ends at the merge. A deploying merge with no such status
   yet is left out until it gets one, and for good after 24 hours.
3. **Change failure rate** SHALL be the failed changes over the deploys
   of 10.1. A failed change is a merged pull request that is a rollback
   (label `auto-rollback`, or a title starting with `revert`) or a fix
   forward (label `fix-forward`, set on a pull request that repairs a
   merged change that broke production instead of reverting it).
4. **Time to restore** SHALL be the median duration of the incidents that
   ended in the window. An incident is either a continuous firing of an
   alert with `action: human` (start: its first firing sample; end: its
   last) or a rollback of 10.3 (start: the merge of the pull request it
   reverts; end: the rollback's merge commit synced, as in 10.2).
   Incidents that overlap are merged into one, so an outage that pages
   and is reverted counts once. Without an incident the figure is "None".
5. EACH metric SHALL show its DORA band, by the thresholds of
   [design, DORA bands](design.md#dora-bands), in colour and in words.
6. THE card SHALL list the last five completed runs of the `ci` workflow
   on `main` (`push` events): the result, the short commit, the pull
   request number from the commit title, when it started and how long it
   took. Renovate's share and the median `ci` run stay on the card.

## Requirement 11: Cluster card, USE and RED

**User story:** As a reader, I want to see how loaded and how healthy
the cluster is right now.

1. FOR each node and for the NAS, THE cluster card SHALL show USE:
   utilisation (CPU, memory, disk or pool), saturation (CPU, memory and
   I/O pressure for the nodes; load per core for the NAS) and errors
   (network errors for the nodes; device and scrub errors for the NAS),
   each over the last 5 minutes or as of now.
2. FOR the shared Gateway, THE card SHALL show RED over the last 5
   minutes: the request rate, the share of `5xx` answers and the p95
   latency.
3. THE card SHALL show the Argo CD applications with their Synced and
   Healthy counts, the container restarts of the last 24 hours, the PVC
   usage (total used over total capacity, and the fullest volume's share
   without its name), the node count and the Talos and Kubernetes
   versions.
4. EACH figure with a threshold SHALL carry a status by the compiled
   rules of [design, Status colours](design.md#status-colours); a figure
   without data SHALL read "No data" in the neutral colour.

## Requirement 12: Security card

**User story:** As a reader, I want to see that the homelab's defences
turn things away, without learning anything that helps an attacker.

1. THE security card SHALL show one tile per security signal, in the
   compiled order of
   [design, Security signals](design.md#security-signals-task-16): the
   count of the last 24 hours as the big number, the count of the last 7
   days, and a sparkline of the 7 days in 28 six-hour bars, the last one
   ending now; all refreshed every collector cycle.
2. EACH count SHALL be one PromQL sum over the whole cluster. NO figure,
   word or bar title on the card SHALL carry an address, a host name, a
   path, a namespace, a pod, a user, a client, or a policy, rule or alert
   name; the card names only the compiled signals, by category.
3. THE security signals SHALL use only data Prometheus holds today. A
   signal without its data is listed as deferred in the design and added
   by a later change once the data exists, never shown as a placeholder.
4. EACH signal's status SHALL follow one of two compiled rules
   ([design, Status colours](design.md#status-colours)): an expected-zero
   signal is `ok` at 0 in 24 hours and `warn` above; a background signal
   is `warn` when its 24-hour count is above 20 and above three times its
   daily mean of the 6 days before, `ok` otherwise. A signal without a
   series is `none` with "No data". No signal SHALL be `bad`: the alerts
   page whoever must act, not the page.
5. Canary tokens SHALL NOT be part of the card (operator, 2026-11-24;
   their own spec, #1618).

## Non-functional requirements

- Platform: arm64 required (amd64 also built, for CI and kind); one
  replica per role; rendered `deploy/` like every app.
- Cost: nothing paid; GHCR public package, GitHub-hosted runners.
- Resources: each role under 32 Mi of memory at rest.
- Language: English, British spelling; reference text follows the
  documentation standard, the page's prose the operator's voice.

## Acceptance criteria

1. From an ephemeral container in the web pod (it shares the pod's
   network identity, so Cilium applies the same policy; the container
   stays in the pod spec until the next rollout):

   ```sh
   pod=$(kubectl -n homelab-dashboard get pod -l app.kubernetes.io/component=web -o name)
   kubectl -n homelab-dashboard debug "$pod" --profile=restricted \
     --image=<the curlimages/curl pin of components/postsync-smoke/job.yaml> -it --quiet -- \
     sh -c 'curl -sm 5 http://kube-prometheus-stack-prometheus.monitoring.svc:9090/-/ready; echo "prometheus exit $?"; curl -sm 5 https://api.github.com; echo "github exit $?"'
   ```

   prints `prometheus exit 28` and `github exit 28` (timeouts). [1.1, 1.2]
2. `kubectl -n homelab-dashboard get "$pod" -o jsonpath='{.spec.automountServiceAccountToken}'`
   prints `false` for the web and the collector pod, neither has a volume
   under `/var/run/secrets/kubernetes.io`, and the namespace has no Role
   or RoleBinding. [1.4]
3. `curl -s https://homelab.nedsi.io/snapshot.json` holds only the
   schema's keys, `generated_at` and `availability.as_of` less than 2
   minutes old, the last of `availability.days` equal to today (Zurich),
   and only the shown apps and certificates. [2.1-2.3]
4. A unit test that adds `sonarr` to the allow-list fails; a snapshot with
   an app outside the allow-list is refused by the web role. [2.3, 2.6]
5. `curl -sI https://homelab.nedsi.io/` returns `200` and every header
   of public-website Requirement 3.2; `POST` returns `405`; `/nope`
   returns `404` with the headers. [3.3, 3.4, 7.1]
6. The golden HTML tests pass; the rendered page contains no `<script`,
   `style=`, `<form` or `<iframe`; the full fixture's page has one card
   per shown app and each of the classes `ok`, `warn`, `bad` and `none`
   next to its status word; the contrast test of `dashboard.css` passes.
   [3.2, 3.7, 3.8]
7. `cosign verify` with the `dashboard-publish` identity passes on the
   running digest, `gh attestation verify` passes, the index lists
   `linux/arm64`, and the `verify-own-images` report for the app's Pods is
   `pass`. [4.2-4.4]
8. A PR that adds a module with a known vulnerability fails `ci`. [4.1]
9. With the collector stopped, the stale alert fires 48 hours after the
   last accepted `generated_at` (promtool rule test); a push signed with
   another key gets `401`, a replayed one `409` (unit tests). [1.5, 5.2]
10. `scripts/dashboard-compare.sh` reports equal figures for three
    consecutive `covers` dates before the switch-over. [6.1, 6.2]
11. The web role's log lines in SigNoz contain no client address or user
    agent. [3.6]
12. The `dashboard` job's screenshot step passes and the run has the
    `dashboard-screenshots` artefact with a 390, 1024, 1440, 1920 and
    2560 px wide rendering of the full fixture; the 390 px one shows every card in one
    column with no cut-off text (looked at in the PR). [3.9, 4.7]
13. `curl -sI http://homelab.nedsi.io/x` returns `301` with
    `Location: https://homelab.nedsi.io/x`; `dig +short homelab.nedsi.io`
    returns the WAN address; `scripts/published-hostnames.sh` prints
    `homelab.nedsi.io` and `scripts/pentest-scope-check.sh` passes;
    `probe_success{app="homelab"}` is 1. [7.1, 7.4]
14. `curl -sI https://blog.nedsi.io/homelab/` and `/homelab` return `301`
    with `Location: https://homelab.nedsi.io/`, and
    `/homelab/snapshot.json` with `Location:
    https://homelab.nedsi.io/snapshot.json`; `tests/test_site_markup.py`
    passes with the Homelab link `https://homelab.nedsi.io/` on the blog,
    the landing page and the app's golden pages. [7.2, 7.3]
15. `probe_success{app="watch"}`, `{app="prometheus"}` and
    `{app="alertmanager"}` are 1; `slo:availability:ratio_rate30d` has a
    series for `watch` and `observability`; the promtool tests of
    `tests/prometheus/slo_test.yaml` cover both, including no burn alert
    for `observability`. [8.1-8.3]
16. With a probe of a shown app failing for 2 minutes, its card says
    "Down" within the next push, and its 30-day figure and today's bar
    drop without waiting for midnight (collector test with a fake
    Prometheus, and once live on a maintenance-silenced app). [2.2, 3.8]
17. The golden pages show the certificates, cluster and project cards
    with each status class next to its word; a table test covers every
    boundary of the certificate, USE, RED and DORA thresholds. [9, 10.5,
    11.4]
18. `collect --once --dry-run` prints DORA figures that
    `scripts/dashboard-dora-check.sh` recounts from `gh` for the same
    window to within one pull request and one minute. [10.1-10.4]
19. The snapshot of a dry run names no namespace, pod, volume or hidden
    app (a test over the full fixture and the dry run's output). [2.3,
    2.7]
20. The `security` block of a dry run holds the compiled signals in
    order, each with `count_24h`, `count_7d` and 28 `buckets`, and no
    string other than the compiled ids and names (a test over the full
    fixture and the dry run's output); each 24-hour count equals the
    design's query run in Grafana for the same instant, within rounding.
    [12.1-12.3]
21. A table test covers both rules of 12.4 on each boundary; the golden
    pages show the security card with `ok`, `warn` and `none` next to
    their words. [12.4]

## Out of scope

- **Home Assistant control and home dashboards.** They stay in Home
  Assistant's own UI and companion app (spec home-automation). The
  collector may later read a few safe Home Assistant values for the public
  page, solar production first, through Prometheus. An internal view
  behind Keycloak is a possible later extension and needs its own spec.
- Solar on the page: public-website task 8, which this app will implement
  once Home Assistant records production.
- Statistics (public-website task 6) and the blog itself.
- Semantic-version releases and a changelog: `main` is production and the
  commit is the version (see the design).
- Vault or OpenBao: a card once it is deployed (8.5), not before.
- Per-app RED or USE, per-namespace figures and anything with a pod or
  volume name (2.7).
- Canary tokens watched by Tetragon and the audit log: #1618, next month
  (12.5).
- The deferred security signals of
  [design, Security signals](design.md#security-signals-task-16), until
  their data exists (12.3).

## Decided defaults

Each default holds until the operator says otherwise.

| Topic | Default | Reason |
| --- | --- | --- |
| Name | `homelab-dashboard`: app, namespace, Application, image `ghcr.io/ned-si/homelab-dashboard` | Matches `homelab-site`; says what it is next to Grafana's dashboards |
| Sources | `dashboard/`, module `github.com/ned-si/homelab/dashboard` | Like `site/`: sources at the top, manifests in `apps/` |
| Language | Go, standard library first | One static binary, `html/template` escaping, a small dependency tree |
| Shape | One binary, `collect` and `web` subcommands, one image | One build, one signature, one digest to bump; the boundary is in the runtime configuration |
| Hand-off | The collector pushes the snapshot to the web role's internal port 9465 every 60 s, to every web pod through a headless Service | Live figures with no egress and no Kubernetes rights for either role; rejected: a ConfigMap (an API write per minute, a sync delay, a Role), the web role pulling (egress on the public pod) |
| Push authentication | Ed25519 signature, private key only in the collector, public key in a ConfigMap; freshness window of 5 min back and 1 min ahead | Integrity is all a public document needs; the web pod holds nothing that can forge a push; rejected: HMAC, mTLS |
| Freshness | Everything live (operator, 2026-11-23): availability with today's bar, certificates and the cluster every cycle, the project every 15 min | The operator's choice over the finished-day rule of 2026-11-20: the page shows an outage or a power cut while it happens, as an observability dashboard does |
| Cadence | Availability, certificates and cluster every 60 s; GitHub every 15 min with the token, hourly without (no DORA figures without it); the 29 finished days of the daily bars recomputed at the first cycle after each Zurich midnight, in memory | The anonymous GitHub quota is shared by the WAN address (#1551) and GraphQL needs a token; a finished day does not change, so it is read once |
| Plex | Probe `https://watch.lilalala.com/identity`, app `watch`; replaces Jellyfin's card (operator, 2026-11-23) | Plex's unauthenticated identity endpoint answers `200` without a session |
| Observability card | One app, the mean of the Grafana, SigNoz, Prometheus and Alertmanager probes; recording rules, no alert | One card for the monitoring stack; Grafana carries no SLO, so it pages through none of the SLO alerts |
| Certificates | From the public probes, grouped by certificate; `ok` > 21 days, `warn` 7-21, `bad` < 7 | What a reader's browser sees; the thresholds of the cert-manager alerts (21 and 7 days) |
| Gateway RED | Envoy's downstream metrics of the Gateway listeners (`listener-secure`, `listener-insecure`), 5-minute rates | The Gateway is every public request's one entry point; Hubble's HTTP metrics see only part of it |
| NAS USE | `truenas-exporter`, extended with load, CPU and memory | The exporter already reads the NAS API; no agent on the NAS |
| DORA | Definitions of [Requirement 10](#requirement-10-project-card-dora-and-ci); bands from the 2023 Accelerate State of DevOps report ([design, DORA bands](design.md#dora-bands)) | Recountable from git and GitHub; the published bands are what readers compare with |
| Sync time | Argo CD Notifications sets the commit status `argocd/<application>` on each successful sync | The only record of when a merge reached the cluster that GitHub can return with the pull request |
| Fix forward | Label `fix-forward`, set by whoever opens the fix | A rule a reader can check; titles alone cannot tell a fix forward from any other fix |
| Security signals | Gateway `4xx`, `403` and `405`; failed sign-ins (Keycloak's event metrics; lockouts left out, they would show which usernames exist); Kyverno admission denials (the API server's webhook counter); ingress packets dropped by Cilium policy; Tetragon runtime detections (the `Runtime*` alerts); each a cluster-wide sum ([design, Security signals](design.md#security-signals-task-16)) | The data Prometheus holds today (checked 2026-11-24); a sum names nothing an attacker can use |
| Security sparkline | 7 days in 28 six-hour bars, the last ending now; the 24 h and 7 d counts as figures | The last four bars are the 24 h; one chart per tile keeps eight tiles readable on a phone; rejected: 168 hourly bars (sub-pixel at 390 px), a 24 h chart and a 7 d chart per tile |
| Security status | Two rules, expected-zero and background; no `bad` | Rejected requests are the internet's background noise, not an incident; paging is the alerts' job |
| Rendering | The web role renders on every request, `Cache-Control: no-cache`, no automatic page refresh | Never older than the last push; automatic reloads disturb screen readers (WCAG 2.2.1); the operator can overrule it with a 60 s refresh |
| Cluster figures | From Prometheus | One source; no ClusterRole; the same numbers as the publisher for the comparison |
| GitHub | A fine-grained read-only token for public repositories, no expiry (operator, 2026-11-20), reviewed yearly, created in task 3; on `401` no anonymous fallback | #1551, and an expired token stays visible |
| Code style | Google Go Style Guide, golangci-lint v2 (`dashboard/.golangci.yaml`), `go-cmp` for test diffs | A published standard with a linter for most of it |
| Versioning | The git commit; images `:<sha>` and `:main` | Trunk-based, `main` is production |
| Address | `https://homelab.nedsi.io/`, its own origin (orchestrator, on the operator's suggestion, 2026-11-20); `blog.nedsi.io/homelab/` a `301` to it | Its own route, certificate, CSP and app, with no path prefix shared with nginx; rejected: `nedsi.io/homelab/` and staying on the blog (see [design, Address](design.md#address)) |
| Look | A dashboard: a grid of panels, big numbers with units, status colours against 99.5%, inline SVG charts, responsive (operator, 2026-11-20) | It is the project's showcase |
| Status colours | 30 days: `ok` with more than 25% of the budget left, `warn` from 0% to 25%, `bad` below 0% (target missed). Per day: `ok` from 99.5%, `warn` from 96.25%, `bad` below (that day alone spent a quarter of the month's budget, the postmortem trigger of `docs/sre.md`). Every other figure: the thresholds of [design, Status colours](design.md#status-colours), taken from an existing alert where one exists | Tied to the SLO, the error-budget policy and the alerts, not to taste |
| Theme | Always dark, the dark palette of `site/assets/css/main.css`; no light variant | Dashboards read better dark; one palette to test |
| Screenshot check | Chrome for Testing's `chrome-headless-shell`, pinned with its checksum; screenshots as an artefact, no pixel diff | A pixel diff breaks on every browser update; the check catches CSP and layout breakage, the artefact shows the look in each PR |
| Switch-over gate | Waived (operator, 2026-11-23): tasks 4-6 go live without the three equal comparisons of 6.2 and acceptance criterion 10, and the publisher is deleted without waiting a daily block (6.4); the security checks of requirement 1 and acceptance criteria 1-3, 5 and 13 still hold | The page is a low-stakes showcase; the only bar is no security hole on a public host |
| Order | Tasks 1-3 right after this amendment; tasks 4 and 5 in the next weekday daytime run, with the operator (operator, 2026-11-20). Redesign tasks 8-15 in order; the tasks that change the rendered page merge only after the operator approves a preview (operator, 2026-11-23). Task 16, the Security card, after task 15, in the same preview as tasks 12-15 when that one has not been shown yet (operator, 2026-11-24) | The public host and the redirect are the steps that can break a public page; the look is the operator's call |
