# Renovate

Config: [`.github/renovate.json5`](../.github/renovate.json5)

## Comment-driven, on purpose

Every pinned version in this repo is preceded by a `# renovate:` comment that
tells Renovate exactly which datasource to query:

```yaml
# renovate: datasource=helm registryUrl=https://helm.cilium.io depName=cilium
targetRevision: 1.20.0
```

```yaml
# renovate: datasource=docker depName=ghcr.io/hotio/qbittorrent
image: ghcr.io/hotio/qbittorrent:release-5.2.3
```

```makefile
# renovate: datasource=github-releases depName=kubernetes-sigs/gateway-api
GATEWAY_API_VERSION := v1.6.1
```

The native `helm-values`, `helmv3` and `argocd` managers are **disabled**:

```json5
enabledManagers: ['custom.regex', 'terraform', 'github-actions']
```

Two reasons. First, no dependency gets tracked twice — with native managers
enabled alongside custom ones, the same chart version can produce two competing
PRs. Second, adding a tracked dependency becomes an explicit, reviewable act: if
Renovate is not opening a PR for something, the comment is missing or wrong, which
is a much easier failure to diagnose than a manager not matching a file pattern.

The trade-off is that a new pinned version with no comment is invisible to
Renovate. That is the intended behaviour, but it does mean the comment is part of
the change, not an afterthought.

## The two custom managers

1. **Annotated version on the following line** — matches `# renovate:` then picks
   up the value after the next `:` or `=`. Covers `targetRevision:`,
   `imageName:`, `tag:`, Makefile variables, `.tf` files.
2. **Annotated full image reference** — matches `image: repo:tag` and extracts just
   the tag, optionally with a digest.

Supported annotation fields: `datasource`, `depName`, `packageName`,
`registryUrl`, `versioning`, `extractVersion`. Only `datasource` is required.

`managerFilePatterns` requires Renovate ≥ 41 (the hosted GitHub App is always
current). On an older self-hosted runner, rename it to `fileMatch`.

## What is held back, and why

Not everything should flow automatically. The rules encode the failures this
cluster has actually had:

| Rule | Behaviour | Reasoning |
|---|---|---|
| **cluster networking** (`cilium`, `gateway-api`) | grouped, never auto-merged | Cilium targets a specific Gateway API version. If the CRDs and Cilium drift, the Gateway stops programming and every route goes dark. |
| **theater stack** (all `ghcr.io/hotio/*`) | grouped, never auto-merged | qBittorrent and the *arr apps share a credential contract. Bumping qBittorrent alone is what broke this cluster for a year — see [runbooks/arr-qbittorrent.md](runbooks/arr-qbittorrent.md). |
| Immich major | dashboard approval | Runs irreversible DB migrations. See [runbooks/immich-upgrade.md](runbooks/immich-upgrade.md). |
| Postgres / VectorChord major | dashboard approval | A major bump refuses to start on an existing data directory. |
| Keycloak major | dashboard approval | Changes OIDC defaults and the admin console; every federated app is downstream. |
| `docker` + `patch` | auto-merged | Leaf application patches are low risk and there are a lot of them. |
| Terraform providers | `rangeStrategy: pin` | Bootstrap should be reproducible. |
| Vulnerability alerts | immediate, unscheduled | Security patches should not wait for the Monday window. |

Everything else follows `config:recommended` on a Monday-night schedule, capped at
5 concurrent PRs.

### hotio version ordering

hotio publishes `release-<x.y.z.build>`, which is not semver. Renovate needs to be
told how to order it:

```json5
versioning: 'regex:^release-(?<major>\\d+)\\.(?<minor>\\d+)\\.(?<patch>\\d+)(?:\\.(?<build>\\d+))?$'
```

Without this, "newest" is decided by string comparison, which reorders builds
arbitrarily.

## Deliberate exception: Seafile

`seafileltd/seafile-mc:11.0-latest` is a floating **minor** tag rather than a pin.
Seafile does not publish patch tags for the community image in a form Renovate can
order, so a full pin would rot into a manual chore. The tag is still bounded to
`11.0.x`, so unlike the old `:latest` usages it cannot cross a major version
silently. Reasoning is in `apps/seafile/deployment.yaml`.

## Adding a dependency

1. Pin the version explicitly. Never `latest`.
2. Add the `# renovate:` comment on the line above.
3. Set `imagePullPolicy: IfNotPresent` for images, so a restart is not an upgrade.
4. Consider whether it belongs in an existing group.

## Verifying the config

Renovate's Dependency Dashboard issue lists everything it detected. If something is
missing, the comment is not matching.

To debug a regex without waiting for a run, use the
[Renovate config validator](https://docs.renovatebot.com/config-validation):

```sh
npx --yes renovate-config-validator .github/renovate.json5
```

## The lesson worth keeping

The old repo had `:latest` with `imagePullPolicy: Always` on qBittorrent, Plex,
Jellyfin, Syncthing and all four *arr apps. That converts **every unrelated pod
restart into an unreviewed upgrade**, and the resulting breakage surfaces months
later looking like something else entirely.

Every one of those is now pinned, and pinning is what makes Renovate useful rather
than decorative: it can only propose an upgrade if the current version is written
down.
