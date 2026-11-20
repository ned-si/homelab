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

Non-goals are listed under [Out of scope](#out-of-scope).

## Glossary

- **App**: `homelab-dashboard`, one Go module in `dashboard/`, one binary,
  one image `ghcr.io/ned-si/homelab-dashboard`, two roles.
- **Collector**: the role that runs in the cluster with read-only access to
  Prometheus and the public GitHub API, computes the public figures and
  writes the snapshot.
- **Web**: the role that answers `https://blog.nedsi.io/homelab/`. It reads
  the snapshot from a read-only mount and serves the page, the snapshot
  and its static assets.
- **Snapshot**: `snapshot.json`, the public figures as one JSON document
  that validates against the app's JSON Schema, stored in the ConfigMap
  `homelab-dashboard-snapshot`.
- **Public figures**, **shown apps**, **personal data**: as defined in the
  public-website spec ([requirements](../public-website/requirements.md#glossary),
  [design, Public figures](../public-website/design.md#public-figures)).
- **Publisher**: today's implementation, `apps/website/publisher/` and the
  `/homelab/` server-side include in `apps/website/nginx.conf`.
- **Switch-over**: the merge after which the Gateway sends
  `blog.nedsi.io/homelab` to the web role instead of nginx.

## Requirement 1: Two roles, one boundary

**User story:** As the operator, I want the public part of the dashboard to
know nothing and reach nothing, so a flaw in it exposes no internal
service or credential.

1. THE web role SHALL run with no ServiceAccount token, no Secret, no
   egress (enforced Cilium policy) and ingress only from the shared
   Gateway on its public port and from Prometheus and the kubelet on its
   metrics port.
2. THE web role SHALL serve only the page, the snapshot and the assets
   compiled into the binary; it SHALL make no outbound connection and
   accept no input other than the request method and path.
3. THE collector SHALL have no route from the Gateway and no listener other
   than its metrics port; egress only to the Prometheus Service, the
   Kubernetes API and `api.github.com:443`.
4. THE collector's Kubernetes rights SHALL be `get` and `patch` on the one
   ConfigMap `homelab-dashboard-snapshot`, nothing else.
5. THE only thing passed from the collector to the web role SHALL be the
   snapshot, through the ConfigMap the web pod mounts read-only.

## Requirement 2: Same figures, same privacy rules

**User story:** As a reader, I want to see that the homelab runs, without
learning anything that helps an attacker or shows who is home.

1. THE snapshot SHALL hold only the public figures of the public-website
   design (availability and error budget per shown app with 30 daily
   values, nodes, Argo CD applications, Talos and Kubernetes versions,
   pull requests merged, Renovate's share, the median `ci` run), plus a
   `schema_version`.
2. EVERY figure SHALL cover yesterday (Europe/Zurich) or the 30 days ending
   with it, read at the end of that day; never the current day.
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

**User story:** As a reader, I want the dashboard to look and behave like
the rest of the blog.

1. THE page SHALL carry the blog's header, navigation bar (Home, Blog,
   Homelab, About) and footer, and the content of today's page: the intro
   text, the figures, the "Coming later" sections.
2. THE page SHALL be server-rendered with Go `html/template`, with no
   JavaScript, no inline style, no form, no iframe and no third-party
   resource; the sparklines are inline SVG built from numbers.
3. EVERY response SHALL carry the headers and the CSP of the public-website
   spec (Requirement 3.2 there), set by the web role itself and by the
   HTTPRoute.
4. THE web role SHALL answer only `GET` and `HEAD` (any other method `405`),
   `404` with the same headers for any other path, and `301` from
   `/homelab` to `/homelab/` with a relative `Location` (no host, no port).
5. WHEN the snapshot is missing or invalid, THE page SHALL show "No figures
   yet"; WHEN it covers a day more than two days ago, THE page SHALL say
   the figures are stale and since when.
6. THE web role's access log SHALL keep `time`, `method`, `path`, `status`,
   `bytes` and the duration, and SHALL NOT keep the client address, the
   user agent, the referrer or the query string.

## Requirement 4: Built and released like production software

**User story:** As the operator, I want the app's image to be traceable to
a reviewed commit, so the cluster runs only what CI built and signed.

1. EVERY pull request touching `dashboard/` SHALL run, inside the required
   `ci` check: `gofmt`, `go vet`, `staticcheck`, `govulncheck`, `go mod
   verify`, and `go test -race` with unit and golden HTML tests; any
   finding fails `ci`.
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

## Requirement 5: Observable

**User story:** As the operator, I want to be told when the dashboard stops
updating, and nothing else.

1. BOTH roles SHALL expose Prometheus metrics on an internal port:
   collector runs by result, errors by source, run duration, the time of
   the last snapshot written; web the age of the snapshot it serves, load
   errors and requests by status.
2. AN alert SHALL page (`action: human`) when the snapshot served is older
   than 48 hours, with a runbook.
3. BOTH roles SHALL log JSON lines (`log/slog`) to stdout, which Vector
   already ships to SigNoz.

## Requirement 6: Migration without a gap

**User story:** As the operator, I want to switch to the app only once it
shows the same figures, and to go back with a revert.

1. THE app SHALL first run next to the publisher, with no public route,
   and its snapshot SHALL be compared with the publisher's `figures.json`
   by a script.
2. THE switch-over SHALL happen only after the comparison has matched for
   three consecutive nights, on a weekday in daytime with the operator.
3. Reverting the switch-over PR SHALL give the publisher's page back with
   no other step.
4. `publisher.py`, its CronJob, ConfigMaps, Role and network policy, the
   SSI location in `nginx.conf`, the Hugo `homelab` page and layout and the
   publisher tests SHALL be deleted only after the switch-over has served
   one nightly update.

## Non-functional requirements

- Platform: arm64 required (amd64 also built, for CI and kind); one
  replica per role; rendered `deploy/` like every app.
- Cost: nothing paid; GHCR public package, GitHub-hosted runners.
- Resources: each role under 32 Mi of memory at rest.
- Language: English, British spelling; reference text follows the
  documentation standard, the page's prose the operator's voice.

## Acceptance criteria

1. From a debug pod with the web pod's labels, a request to the Prometheus
   Service and to `https://api.github.com` times out; the web pod has no
   `/var/run/secrets/kubernetes.io` mount. [1.1, 1.2]
2. `kubectl auth can-i --list` for the collector's ServiceAccount shows
   only `get` and `patch` on `configmaps/homelab-dashboard-snapshot`. [1.4]
3. `curl -s https://blog.nedsi.io/homelab/snapshot.json` holds only the
   schema's keys, `covers` equal to yesterday and only the shown apps.
   [2.1-2.3]
4. A unit test that adds `sonarr` to the allow-list fails; a snapshot with
   an app outside the allow-list is refused by the web role. [2.3, 2.6]
5. `curl -sI https://blog.nedsi.io/homelab/` returns `200` and every header
   of public-website Requirement 3.2; `POST` returns `405`;
   `/homelab/nope` returns `404` with the headers; `/homelab` returns
   `301` with `Location: /homelab/`. [3.3, 3.4]
6. The golden HTML tests pass and the rendered page contains no `<script`,
   `style=`, `<form` or `<iframe`. [3.2]
7. `cosign verify` with the `dashboard-publish` identity passes on the
   running digest, `gh attestation verify` passes, the index lists
   `linux/arm64`, and the `verify-own-images` report for the app's Pods is
   `pass`. [4.2-4.4]
8. A PR that adds a module with a known vulnerability fails `ci`. [4.1]
9. With the collector stopped, the stale alert fires 48 hours after the
   last `computed_at` (promtool rule test). [5.2]
10. `scripts/dashboard-compare.sh` reports equal figures for three
    consecutive `covers` dates before the switch-over. [6.1, 6.2]
11. The web role's log lines in SigNoz contain no client address or user
    agent. [3.6]

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
| Hand-off | The snapshot in a ConfigMap the web pod mounts read-only | The web pod needs no token and no egress; the pattern the publisher proved |
| Rendering | The web role renders from the snapshot | Templates live with the server; the ConfigMap holds data only |
| Collector schedule | A Deployment that collects at 03:45 Zurich and retries until it succeeds | Real metrics and rate-limit-aware retries without a Pushgateway |
| Cluster figures | From Prometheus at the end of `covers`, as the publisher does | Yesterday's figures from one source; no ClusterRole; an exact comparison |
| GitHub | A fine-grained read-only token, optional; unauthenticated with reset-aware retries until it exists | #1551: the WAN address shares the anonymous quota |
| Versioning | The git commit; images `:<sha>` and `:main` | Trunk-based, `main` is production |
