# Website

The public pages: the landing page at `https://nedsi.io/`
(`apps/website/landing/`, a ConfigMap), the blog at `https://blog.nedsi.io/`
(`site/`, Hugo, in the `homelab-site` image) and the dashboard at
`https://homelab.nedsi.io/` (`dashboard/`, [homelab-dashboard.md](homelab-dashboard.md)).
The spec is [.kiro/specs/public-website/](../.kiro/specs/public-website/).

## Shared layout

Every public page uses one container, header, navigation bar and footer
geometry, so switching pages never moves the nav or the content edge.

| What | Value |
| --- | --- |
| Container | `body`: `max-width: 72rem`, padding `1.5rem 1.25rem 3rem`, centred |
| Font | `1.0625rem/1.6 system-ui, -apple-system, "Segoe UI", sans-serif` |
| Header | `<header class="site"><nav class="site" aria-label="Site">`, links Home, Blog, Homelab, About |
| Blog text | `main > .prose`, `max-width: 44rem`, from the container's left edge |

Rules:

- The layout is defined once, in `site/assets/css/layout.css`. Edit only
  that file, then run `task site:layout-sync`: it copies it to
  `apps/website/landing/layout.css` and
  `dashboard/internal/web/assets/layout.css`. `scripts/ci/site-check.sh`
  fails when a copy differs.
- A page's own stylesheet (`main.css`, `landing.css`, `dashboard.css`)
  holds colours and its own components, never a rule of `layout.css`.
- The nav links are `NAV` in `scripts/ci/site_markup.py`; the check fails
  when a page's nav differs from it (only `aria-current` may differ).
- `scripts/ci/layout-check.sh <built blog>`, a step of the `site` job,
  renders the landing page, the blog home, About, privacy, the newest
  article and the dashboard's fixture page in the pinned
  `chrome-headless-shell` at 1920x1080 and 390x844, and fails when the
  container or the nav differs by more than 1 px from the landing page.
  Locally: `CHROME=<a Chrome binary> scripts/ci/layout-check.sh <dir>` after
  `SITE_OUT=<dir> scripts/ci/site-check.sh --all`.

A layout change reaches the blog and the dashboard with their next image
deploys (digest bumps of `homelab-site` and `homelab-dashboard`); the
landing page is live with the merge.

## Why it is like this

- One copied file with a byte check: Hugo, the landing page's ConfigMap
  generator and Go `embed` cannot read one shared file outside their own
  tree, and a stylesheet served from one origin to the others would break
  the `'self'`-only CSP. Rejected: hand-kept copies (how the widths drifted
  apart) and a pixel diff (breaks on every browser update; geometry is what
  has to match).
- `72rem`: the dashboard's three `17rem` columns need it; the blog keeps
  its reading measure inside the same container.
