# Website

The public pages: the landing page at `https://nedsi.io/`
(`apps/website/landing/`, a ConfigMap), the blog at `https://blog.nedsi.io/`
(`site/`, Hugo, in the `homelab-site` image), the dashboard at
`https://homelab.nedsi.io/` (`dashboard/`, [homelab-dashboard.md](homelab-dashboard.md))
and the tech radar at `https://techradar.nedsi.io/` ([techradar.md](techradar.md)).
Every page comes in a dark and a light theme and in English and French.
The specs are [.kiro/specs/public-website/](../.kiro/specs/public-website/)
and [.kiro/specs/site-theme-language/](../.kiro/specs/site-theme-language/).

## Shared layout

Every public page uses one container, header, navigation bar and footer
geometry, so switching pages never moves the nav or the content edge.

| What | Value |
| --- | --- |
| Container | `body`: `max-width: 72rem`, padding `1.5rem 1.25rem 3rem`, centred |
| Font | `1.0625rem/1.6 system-ui, -apple-system, "Segoe UI", sans-serif` |
| Header | `<header class="site">`: `<nav class="site" aria-label="Site">` with Home, Blog, Homelab, Tech radar, About, then `<p class="prefs">` at the top right with the language and theme toggles |
| Blog text | `main > .prose`, `max-width: 44rem`, from the container's left edge |

Rules:

- The layout is defined once, in `site/assets/css/layout.css`. Edit only
  that file, then run `task site:layout-sync`: it copies it to
  `apps/website/landing/layout.css`,
  `dashboard/internal/web/assets/layout.css`,
  `techradar/internal/radar/assets/layout.css`,
  `apps/website/techradar/layout.css` and
  `drumcharts/internal/site/assets/layout.css`. `scripts/ci/site-check.sh`
  fails when a copy differs.
- A page's own stylesheet (`main.css`, `syntax.css`, `landing.css`,
  `dashboard.css`, `techradar.css`) holds its own components, never a
  rule of `layout.css` and never a colour ([Palette](#palette)).
- The nav links are `NAV` in `scripts/ci/site_markup.py`, one list per
  language; the check fails when a page's nav differs from the list of its
  language (only `aria-current` may differ).
- `scripts/ci/layout-check.sh <built blog>`, a step of the `site` job,
  renders the landing page, the blog home, About, privacy, the newest
  article, the dashboard's fixture page and the tech radar in the pinned
  `chrome-headless-shell` at 1920x1080 and 390x844, and fails when the
  container, the nav or the preferences differ by more than 1 px from the
  landing page. The French landing page, blog home, About and privacy
  pages are compared with the French landing page, because the French
  link texts are longer.
  Locally: `CHROME=<a Chrome binary> scripts/ci/layout-check.sh <dir>` after
  `SITE_OUT=<dir> scripts/ci/site-check.sh --all`.

A layout change reaches the blog and the dashboard with their next image
deploys (digest bumps of `homelab-site` and `homelab-dashboard`); the
landing page and the tech radar are live with the merge.

## Theme

Dark is the default for everyone. The sun and moon icons in the
preferences are plain links; there is no JavaScript.

| Request | Response |
| --- | --- |
| `GET /theme.css` | `200`, the light palette with `Cookie: theme=light`, the dark one otherwise; `Cache-Control: no-store`, `Vary: Cookie` |
| `GET /set-theme/light<path>` | `303`, `Location: <path>`, sets the theme cookie |
| `GET /set-theme/dark<path>` | `303`, `Location: <path>`, deletes the cookie (`Max-Age=0`) |
| Either, with `Sec-Fetch-Site` other than `same-origin`, `same-site` or `none`, or with any `Sec-Purpose` | `303`, no `Set-Cookie`: a cross-site navigation or a prefetch changes nothing |
| `/set-theme/` with another theme, or a `<path>` outside `^/[A-Za-z0-9._~/-]*$` | `404`, no `Set-Cookie` |

Every page links `/theme.css` after its own stylesheet, and its theme
links carry the page's own path (`/set-theme/light/fr/about/`). The HTML
is the same in both themes, so only `/theme.css` varies by cookie and
the pages keep their caching.

| Host | `/theme.css` and `/set-theme/` |
| --- | --- |
| `nedsi.io`, `blog.nedsi.io`, `techradar.nedsi.io` | nginx: the maps `$theme`, `$theme_click` and `$theme_cookie` in `apps/website/nginx.conf`, the locations in `apps/website/theme.conf` (a key of ConfigMap `website-nginx`), included by each server block |
| `homelab.nedsi.io` | Go: `route` and `setTheme` in `dashboard/internal/web/public.go`, over the embedded palette copies |

The cookie is `theme=light; Domain=nedsi.io; Path=/; Max-Age=31536000;
Secure; HttpOnly; SameSite=Lax`, the only cookie on any public page. It is
set only on the reader's click on the sun, holds nothing but `light`, and
is read only to pick the palette; no access log records it. The privacy
page (`site/content/privacy.md` and `privacy.fr.md`) describes it, which
is why there is no consent banner
([design, Why no banner](../.kiro/specs/site-theme-language/design.md#why-no-banner)).
Keep the privacy page true when anything about the cookie changes.

Check it live:

```sh
curl -sI https://blog.nedsi.io/theme.css | grep -iE 'cache-control|vary'
curl -s -H 'Cookie: theme=light' https://blog.nedsi.io/theme.css | grep color-scheme
curl -sI https://blog.nedsi.io/set-theme/light/about/ | grep -iE '^location|^set-cookie'
```

Expected: `cache-control: no-store` and `vary: Cookie`; `color-scheme:
light;`; `location: /about/` and the `set-cookie` line above. The same
works on the other three hosts. CI runs these cases against the real
nginx config (`scripts/ci/site-serve-check.sh`) and the dashboard's
handler tests; the website's PostSync smoke runs them through the
Gateway after every sync.

## Palette

`site/assets/css/theme-dark.css` and `site/assets/css/theme-light.css`
are the only place a colour is written. Both hold the same custom
properties in `:root`, their `color-scheme`, and one rule that hides the
link to the theme already shown (`.prefs .to-dark` or `.prefs .to-light`).
The values and their users are in
[design, Palette](../.kiro/specs/site-theme-language/design.md#palette).

| Host | Copies, written by `task site:layout-sync` |
| --- | --- |
| Blog | none: Hugo publishes both files, and the dark one also as `/theme.css` for `task site:serve` |
| Landing page | `apps/website/landing/theme-dark.css`, `theme-light.css`, keys of ConfigMap `website-landing` |
| Tech radar | `techradar/internal/radar/assets/`, embedded; the generator writes them into `apps/website/techradar/` |
| Dashboard | `dashboard/internal/web/assets/`, embedded |
| Drum charts | `drumcharts/internal/site/assets/`, embedded |

`scripts/ci/site-check.sh` fails when a copy differs from its source,
and `site_markup.py --css` fails on a colour literal (`#hex`, `rgb(`,
`hsl(`, a named colour) in any other stylesheet.

### Add a colour

1. Add the property to both palette files, for example
   `--accent: #6cb6ff;` in `theme-dark.css` and `--accent: #0a58a8;` in
   `theme-light.css`.
2. Add it to a row of `PAIRS` in `scripts/ci/site_contrast.py`: as a
   foreground with the backgrounds it is used on, or as a background.
   Text needs 4.5:1 (WCAG 1.4.3), a colour that carries meaning without
   text 3:1 (1.4.11). A property in no pair fails the check.
3. Check the contrast and copy the files:

   ```sh
   python3 scripts/ci/site_contrast.py site/assets/css
   task site:layout-sync
   ```

   Expected: `site_contrast: <n> pairs pass in each theme`, exit 0. A
   failing pair prints `site_contrast: FAIL` with both colours and the
   ratio; change the value until it passes.
4. Use it as `var(--accent)` in the page's stylesheet, then run
   `task site:build`. Expected: exit 0 with no `FAIL`.

The dashboard's and the radar's `TestContrast` read their copies, so
`go test ./...` in `dashboard/` and `techradar/` checks their own pairs
in both themes. A palette change reaches the blog and the dashboard with
their next image deploys.

## Languages

English stays at the existing URLs. French is the same path under
`/fr/`: `https://blog.nedsi.io/fr/about/`, `https://nedsi.io/fr/`,
`https://homelab.nedsi.io/fr/`, `https://techradar.nedsi.io/fr/`. The
language switch shows only the other language ("FR" on English pages,
"EN" on French ones, named "Français" or "English" for screen readers)
and links the same page in it, so the language needs no cookie and nothing redirects by
`Accept-Language`.

Every page has `<html lang="en-GB">` or `lang="fr-CH"`, a canonical to
its own URL, and, when it has a translation, the absolute `hreflang`
links `en`, `fr` and `x-default` (the English URL). The blog has one
feed per language: `/index.xml` and `/fr/index.xml` (the French
translations only). `scripts/ci/site_markup.py` checks all of it on
every rendered page.

| Host | English | French | Strings |
| --- | --- | --- | --- |
| `nedsi.io` | `apps/website/landing/index.html` | `apps/website/landing/index-fr.html`, served at `/fr/` by `location = /fr/` | in the page |
| `blog.nedsi.io` | `site/content/<page>.md`, `<bundle>/index.md` | `<page>.fr.md`, `<bundle>/index.fr.md` next to it | `site/i18n/en.yaml`, `fr.yaml` |
| `homelab.nedsi.io` | `/` | `/fr/` | the catalogue in `dashboard/internal/web/i18n.go` ([homelab-dashboard.md](homelab-dashboard.md#languages)) |
| `techradar.nedsi.io` | `index.html` | `index-fr.html` | the catalogue in `techradar/internal/radar/i18n.go`, `reason_fr` per entry ([techradar.md](techradar.md#add-or-move-an-entry)) |

### Add a French page to the blog

1. Next to the English file, write its translation:
   `site/content/<page>.fr.md` for a single file,
   `site/content/<bundle>/index.fr.md` for a bundle. Keep the English
   tags, so the tag pages match.
2. A string that a layout prints goes in both `site/i18n/en.yaml` and
   `site/i18n/fr.yaml` under the same key, used as `{{ T "<key>" }}`.
3. Build and check:

   ```sh
   task site:build
   ```

   Expected: exit 0 with no `FAIL`. It fails on a missing i18n key
   (`--printI18nWarnings`, warnings are errors), an English page without
   its French file, a French file without its English original, and a
   wrong `lang`, canonical, `hreflang` or toggle link.

Hugo links the two files as translations, so the toggles, the
`hreflang` links and the French home list need no other change.

### A new article

An article ships with its translation or with a fallback stub. Without
a translation, write the stub:

```sh
task site:fallback -- site/content/posts/<slug>
```

Expected: `site.sh: wrote site/content/posts/<slug>/index.fr.md`. The
stub holds the English `title`, `date` and `summary`, `fallback: true`
and `sitemap: {disable: true}`. Its page at `/fr/posts/<slug>/` shows the
French navigation, a note in French that the article is only in English
for now with a link to it, then the English text in `lang="en-GB"`. It
has no `hreflang` links, its canonical is the English article, and it is
not in the French feed. `task site:build` fails when an article has
neither file or a stub's fields differ from the English ones.

A real translation replaces the stub: delete `fallback` and `sitemap`
and write the French text. Article translations open as draft pull
requests, which only the operator marks ready (public-website
Requirement 2.5).

### Translation conventions

The French text follows
[design, Translation](../.kiro/specs/site-theme-language/design.md#translation):

- Swiss French (`fr-CH`), "vous" for the reader, "septante" and
  "nonante" where a number is spelled out.
- The operator's voice: a translation of the validated English text,
  not a rewrite.
- French typography: a no-break space (U+00A0) before `:` and inside
  `« »`, a narrow no-break space (U+202F) before `;`, `!`, `?` and `%`.
- No em dash (U+2014). "Agents", never "bots" or "robots".
- Terms French-speaking engineers use in English stay in English
  (cluster, pull request, GitOps, SLO). An English expression set apart
  in the French text, such as *pull request* or *platform engineering*,
  is in italics: `<em>` in the landing page, `*pull request*` in
  Markdown, the Go catalogues and `reason_fr` (the generators turn it
  into `<em>`); everyday loanwords such as cluster stay upright.
  Product names, commands, code and paths do not change.

## Why it is like this

- One copied file with a byte check: Hugo, the landing page's ConfigMap
  generator and Go `embed` cannot read one shared file outside their own
  tree, and a stylesheet served from one origin to the others would break
  the `'self'`-only CSP. Rejected: hand-kept copies (how the widths drifted
  apart) and a pixel diff (breaks on every browser update; geometry is what
  has to match).
- `72rem`: the dashboard's three `17rem` columns need it; the blog keeps
  its reading measure inside the same container.
- A stylesheet that varies by cookie, not HTML: the pages stay static,
  cacheable and identical for every reader. Rejected: a class on `<html>`
  set per request (every page would vary by cookie and lose its caching),
  `prefers-color-scheme` alone (no toggle, and dark is the chosen
  default) and a CSS checkbox (forgets the choice on the next page).
- The language in the path, not in a cookie: one URL shows the same page
  to everyone, so feeds, `hreflang`, crawlers and caches work, and there
  is no second cookie to explain. The `/fr/` prefix is Hugo's standard
  and one prefix for nginx and the Go router. Rejected: a suffix
  (`/about/fr/`), which needs per-page rewrites.
- Fallback stubs, not Hugo's automatic fill-in of missing translations:
  the stub is explicit and checked by CI on the pinned Hugo.
