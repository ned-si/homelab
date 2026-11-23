---
kind: change
status: active
created: 2026-11-20
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
  Live figures are the cluster facts, the project figures and, later,
  solar production; availability and error budget are per finished day
  ([design, Freshness](design.md#freshness)).
- **Publisher**: today's implementation, `apps/website/publisher/` and the
  `/homelab/` server-side include in `apps/website/nginx.conf`.
- **Status**: how an availability figure compares with the 99.5% target:
  `ok` (met), `warn` (at risk), `bad` (missed) or `none` (no data); the
  rules are in [design, Status colours](design.md#status-colours).
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

1. THE snapshot SHALL hold only the public figures of the public-website
   design (availability and error budget per shown app with 30 daily
   values, nodes, Argo CD applications, Talos and Kubernetes versions,
   pull requests merged, Renovate's share, the median `ci` run), plus a
   `schema_version`.
2. Cluster facts (nodes, Argo CD applications, Talos and Kubernetes
   versions), project figures and, later, solar production MAY be near
   real time (refreshed at most every minute). Availability and error
   budget SHALL cover finished days only (up to yesterday, Europe/Zurich),
   because a live availability figure shows outages and power cuts as
   they happen.
3. THE shown apps SHALL be an allow-list compiled into the binary; the
   *arr apps, qBittorrent, the indexers and the rest of the download
   tooling SHALL never be queried, written or rendered, and a unit test
   SHALL fail if one is added.
4. AN app with fewer than 30 days of data SHALL show "since <date>" and no
   error budget.
5. Solar production MAY be added later (production only).
   Household consumption, grid import and export, battery, charging,
   presence and anything else that reveals whether someone is home SHALL
   never be collected or shown.
6. THE web role SHALL re-validate the snapshot it loads (schema, ranges,
   the compiled allow-list) and SHALL refuse a document that fails, keeping
   the last good one.

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
   figures yet"; WHEN the live figures are more than 5 minutes old, THE
   page SHALL say from when; WHEN the daily block covers a day more than
   two days ago, THE page SHALL say the availability figures are stale and
   since when.
6. THE web role's access log SHALL keep `time`, `method`, `path`, `status`,
   `bytes` and the duration, and SHALL NOT keep the client address, the
   user agent, the referrer or the query string.
7. THE page SHALL be a grid of panels: one card per shown app, a cluster
   panel and a project panel with each figure as a large number and its
   unit, and the "Coming later" panels.
8. EACH shown app's card SHALL show its 30-day availability with its
   status in colour and in words, its error budget left as a meter, and
   its 30 daily values as a bar chart, each bar coloured by that day's
   status. Colour SHALL never be the only carrier of a status, and every
   text and status colour SHALL have a contrast of at least 4.5:1 against
   its background.
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
   pinned headless browser at a phone and a desktop width, inside `ci`;
   a browser error, a blocked resource or a CSP violation fails `ci`, and
   the screenshots are attached to the run.

## Requirement 5: Observable

**User story:** As the operator, I want to be told when the dashboard stops
updating, and nothing else.

1. BOTH roles SHALL expose Prometheus metrics on an internal port:
   collector runs by block and result, errors by source, run duration,
   pushes by result, whether the GitHub token is accepted; web the age of
   the snapshot it serves and of its daily block, refused pushes by
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
   schema's keys, `generated_at` less than 2 minutes old, `daily.covers`
   equal to yesterday after 03:45 Zurich, and only the shown apps.
   [2.1-2.3]
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
    `dashboard-screenshots` artefact with a 390 px and a 1280 px wide
    rendering of the full fixture; the 390 px one shows every card in one
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
| Freshness | Live: cluster, project, solar production. Per finished day: availability | A live availability figure reveals outages and power cuts as they happen; the operator can overrule it |
| Cadence | Cluster every 60 s; GitHub every 15 min with the token, hourly without; the daily block once a day after 03:45 Zurich, in memory | The anonymous GitHub quota is shared by the WAN address (#1551); 03:45 lets the midnight rules and the search index settle |
| Rendering | The web role renders on every request, `Cache-Control: no-cache`, no automatic page refresh | Never older than the last push; automatic reloads disturb screen readers (WCAG 2.2.1); the operator can overrule it with a 60 s refresh |
| Cluster figures | From Prometheus | One source; no ClusterRole; the same numbers as the publisher for the comparison |
| GitHub | A fine-grained read-only token for public repositories, no expiry (operator, 2026-11-20), reviewed yearly, created in task 3; on `401` no anonymous fallback | #1551, and an expired token stays visible |
| Code style | Google Go Style Guide, golangci-lint v2 (`dashboard/.golangci.yaml`), `go-cmp` for test diffs | A published standard with a linter for most of it |
| Versioning | The git commit; images `:<sha>` and `:main` | Trunk-based, `main` is production |
| Address | `https://homelab.nedsi.io/`, its own origin (orchestrator, on the operator's suggestion, 2026-11-20); `blog.nedsi.io/homelab/` a `301` to it | Its own route, certificate, CSP and app, with no path prefix shared with nginx; rejected: `nedsi.io/homelab/` and staying on the blog (see [design, Address](design.md#address)) |
| Look | A dashboard: a grid of panels, big numbers with units, status colours against 99.5%, inline SVG charts, responsive (operator, 2026-11-20) | It is the project's showcase |
| Status colours | 30 days: `ok` with more than 25% of the budget left, `warn` from 0% to 25%, `bad` below 0% (target missed). Per day: `ok` from 99.5%, `warn` from 96.25%, `bad` below (that day alone spent a quarter of the month's budget, the postmortem trigger of `docs/sre.md`) | Tied to the SLO and the error-budget policy, not to taste |
| Theme | Always dark, the dark palette of `site/assets/css/main.css`; no light variant | Dashboards read better dark; one palette to test |
| Screenshot check | Chrome for Testing's `chrome-headless-shell`, pinned with its checksum; screenshots as an artefact, no pixel diff | A pixel diff breaks on every browser update; the check catches CSP and layout breakage, the artefact shows the look in each PR |
| Order | Tasks 1-3 right after this amendment; tasks 4 and 5 in the next weekday daytime run, with the operator (operator, 2026-11-20) | The public host and the redirect are the steps that can break a public page |
