# Design: site-theme-language

## Overview

Every public page has one theme contract and one URL scheme:

- **Theme.** The page links `/theme.css`. The server returns the dark
  or the light palette from the `theme` cookie. The sun and moon icons
  link to `/set-theme/<theme><path>`, which sets or deletes the cookie
  and redirects with `303` to the page. The HTML is the same in both
  themes, so only `/theme.css` varies by cookie.
- **Language.** English stays at the current paths. French is the same
  path under `/fr/`. The toggle is a plain link to the other language's
  page, so the language needs no cookie.

nginx serves `nedsi.io`, `blog.nedsi.io` and `techradar.nedsi.io`, and
the Go web role serves `homelab.nedsi.io`. Both apply the contract the
same way, with the same paths, the same headers and the same cookie.

## How the theme is served

| Request | Response |
| --- | --- |
| `GET /theme.css`, no cookie or any value other than `light` | `200`, the dark palette, `Content-Type: text/css`, `Cache-Control: no-store`, `Vary: Cookie` |
| `GET /theme.css`, `Cookie: theme=light` | `200`, the light palette, the same headers |
| `GET /set-theme/light<path>` | `303`, `Location: <path>`, `Set-Cookie: theme=light; Domain=nedsi.io; Path=/; Max-Age=31536000; Secure; HttpOnly; SameSite=Lax`, `Cache-Control: no-store` |
| `GET /set-theme/dark<path>` | `303`, `Location: <path>`, `Set-Cookie: theme=; Domain=nedsi.io; Path=/; Max-Age=0; Secure; HttpOnly; SameSite=Lax`, `Cache-Control: no-store` |
| `GET /set-theme/` with any other theme, or a `<path>` outside `^/[A-Za-z0-9._~/-]*$` | `404`, the host's not-found page, no `Set-Cookie` |

`<path>` is the page's own path, built into the HTML at render time
(`/about/`, `/fr/about/`, `/`). The allowed characters cover every path
the four hosts serve, because French pages keep the English slugs. A
`%0d%0a` decodes to characters outside the set, so it cannot add a
header. A `%5c` decodes to `\`, which browsers read like `/`, and it is
outside the set too. A path that starts with `//` would be a
protocol-relative URL. nginx merges slashes before matching and Go
rejects it, so the `Location` always starts with exactly one `/` on
the same host.

A `GET` that sets a cookie is acceptable here. It changes only how the
reader's own next page looks. A third-party page can make a browser
fetch it, and the worst outcome is the reader seeing the other theme.
Every theme link carries `rel="nofollow"`, and the blog's `robots.txt`
has `Disallow: /set-theme/`.

## Per host

The contract works on every host, so no host falls back to
`prefers-color-scheme`. That fallback, dark or light from the reader's
system when no cookie is set, was the plan B for a host that could not
read a cookie. The operator also chose dark as the default for
everyone, so it is not used.

| Host | Served by | `/theme.css` | `/set-theme/` | French |
| --- | --- | --- | --- | --- |
| `nedsi.io` | nginx, ConfigMap `website-landing` | `try_files /theme-$theme.css` | `theme.conf` | `location = /fr/` serves `index-fr.html` |
| `blog.nedsi.io` | nginx, image `homelab-site` (Hugo output) | the same; Hugo publishes both palette files | `theme.conf` | Hugo's `/fr/` tree, `/fr/404.html` |
| `techradar.nedsi.io` | nginx, ConfigMap `website-techradar` | the same; the generator writes both palette files | `theme.conf` | `location = /fr/` serves `index-fr.html` |
| `homelab.nedsi.io` | Go web role | a handler over the embedded copies | a handler | `/fr/` renders the French catalogue |

Known limits, accepted:

- **Cookies blocked.** A browser that refuses cookies stays dark, and
  the sun reloads the page unchanged.
- **Local preview.** `task site:serve` (`hugo server`) has no nginx.
  Hugo also publishes `/theme.css` as a copy of the dark palette, so the
  preview and the layout check's static copies are styled. The toggle
  returns `404` locally.
- **Back button.** The page the reader returns to can come from the
  back/forward cache with the old theme until it reloads.

### nginx

In the `http` block of `apps/website/nginx.conf`:

```nginx
# The theme (.kiro/specs/site-theme-language/design.md#nginx).
map $cookie_theme $theme {
    light   light;
    default dark;
}
map $uri $theme_cookie {
    ~^/set-theme/light/ "theme=light; Domain=nedsi.io; Path=/; Max-Age=31536000; Secure; HttpOnly; SameSite=Lax";
    default             "theme=; Domain=nedsi.io; Path=/; Max-Age=0; Secure; HttpOnly; SameSite=Lax";
}
```

`apps/website/theme.conf` is a second key of the `website-nginx`
ConfigMap, included by the `blog.nedsi.io`, `nedsi.io` and
`techradar.nedsi.io` server blocks:

```nginx
location = /theme.css {
    add_header Cache-Control "no-store";
    add_header Vary "Cookie";
    try_files /theme-$theme.css =404;
}
location ~ "^/set-theme/(?:light|dark)(?<back>/[A-Za-z0-9._~/-]*)$" {
    add_header Set-Cookie $theme_cookie;
    add_header Cache-Control "no-store";
    return 303 $back;
}
location /set-theme/ {
    return 404;
}
```

- `absolute_redirect off` (already set) keeps the `Location` relative.
  `merge_slashes` (on by default) means `$back` never starts with `//`.
- The regex location wins over the `/set-theme/` prefix, which catches
  everything the regex refuses.
- `add_header` in a location replaces the inherited ones. That is
  intended: these locations need only their own headers, and the
  Gateway's `ResponseHeaderModifier` adds the security headers on every
  response.
- The access log format is unchanged: it holds no header, so no cookie.
- The French landing and radar pages live in flat ConfigMaps (keys
  cannot hold `/`), so `index-fr.html` sits next to `index.html`:

  ```nginx
  location = /fr/ { try_files /index-fr.html =404; }
  location = /fr  { return 301 /fr/; }
  location = /index-fr.html { internal; }
  ```

- In the blog's server, `location /fr/ { error_page 404 /fr/404.html;
  ... }`, so a missing French path gets the French 404 page.

### Go web role

In `dashboard/internal/web/public.go`, `route` gains two cases:

- `/theme.css`: `Cache-Control: no-store`, `Vary: Cookie`, and the
  embedded `assets/theme-light.css` when `r.Cookie("theme")` has the
  value `light`, otherwise `assets/theme-dark.css`. Neither file gets
  a fingerprinted path or an `integrity` attribute, because the body
  varies.
- Paths with the prefix `/set-theme/`: the theme must be `light` or
  `dark`, and the rest must match `^/[A-Za-z0-9._~/-]*$` and must not
  start with `//`. Anything else gets `serveNotFound`. Otherwise
  `http.SetCookie` with the attributes above (`MaxAge: -1` writes
  `Max-Age=0`), `Location: <path>` and `303`.

The page's HTML, its ETag and `Cache-Control: no-cache` do not change.
The `<meta name="color-scheme" content="dark">` line goes, because the
palette sets `color-scheme`. The access log line already holds no
header.

The Go role could also render a class on `<html>` per request. It does
not, because one contract keeps one header markup, one set of serve
checks and HTML that does not depend on the cookie on all four hosts.

## Palette

`site/assets/css/theme-dark.css` and `site/assets/css/theme-light.css`
are the only place a colour is written. They hold the same custom
property names, `:root { color-scheme: dark | light; ... }`, and one
rule that hides the link to the current theme:

```css
/* theme-dark.css */
.prefs .to-dark { display: none; }
/* theme-light.css */
.prefs .to-light { display: none; }
```

| Property | Dark (today's values) | Light (starting values) | Used by |
| --- | --- | --- | --- |
| `--bg` | `#17191b` | `#fdfdfc` | every page |
| `--fg` | `#e3e5e7` | `#1d1f21` | every page |
| `--muted` | `#a0a6ab` | `#5c6166` | every page |
| `--link` | `#79b8ff` | `#0b5cad` | every page, the focus ring |
| `--rule` | `#34383c` | `#d8dadc` | borders, decorative |
| `--code-bg` | `#212427` | `#f3f4f5` | blog code blocks |
| `--panel` | `#212427` | `#f3f4f5` | dashboard cards |
| `--tile` | `#1a1c1f` | `#e9ebed` | dashboard stat tiles |
| `--ok`, `--warn`, `--bad`, `--none` | `#3fb950`, `#d29922`, `#f85149`, `#a0a6ab` | `#116329`, `#8a5c00`, `#b62324`, `#5c6166` | dashboard status |
| `--ring-adopt`, `--ring-trial`, `--ring-assess`, `--ring-hold`, `--blip-text` | the tech radar's values | the tech radar's light values | tech radar |
| `--syn-*` (about ten: comment, keyword, string, number, name, function, operator, error) | chroma's `github-dark` | chroma's `github` | blog code |

The light status colours start from GitHub Primer's light palette,
darkened so that they reach 4.5:1 on `--tile`. The contrast check
decides the final values, and the PR that sets them records them in
this table.

Where the copies live: the shared layout's pattern (public-website
design, Shared layout). There are byte-identical copies, `task
site:layout-sync` writes them and `scripts/ci/site-check.sh` fails on
a difference.

| Host | Files |
| --- | --- |
| Blog | Hugo publishes `site/assets/css/theme-*.css` to `/theme-dark.css`, `/theme-light.css`, and the dark one also to `/theme.css` (`resources.Copy`, then `.Publish`) |
| Landing page | `apps/website/landing/theme-dark.css`, `theme-light.css`, keys of `website-landing` |
| Tech radar | the generator writes both into `apps/website/techradar/` |
| Dashboard | `dashboard/internal/web/assets/theme-dark.css`, `theme-light.css`, embedded |

The site stylesheets (`main.css`, `syntax.css`, `landing.css`,
`dashboard.css`, `techradar.css`, `layout.css`) use `var(--...)` only.
The blog's `prefers-color-scheme` block and the dashboard's palette go,
and `syntax.css` is regenerated with variables. `site_markup.py` fails
on a colour literal (`#hex`, `rgb(`, `hsl(`, a named colour) in any of
them.

## Markup

The preferences sit in `header.site`, after `nav.site`, at the top
right. The shared layout (`layout.css`) gains the rules:
`header.site` as a flex row with `justify-content: space-between`,
`.prefs` as a flex row with a `0.75rem` gap, the icon size, the focus
ring of `nav.site a`, and a `.vh` visually-hidden class.

```html
<header class="site">
<nav class="site" aria-label="Site">...</nav>
<p class="prefs">
<span class="lang"><span aria-current="true">EN</span> <a href="https://blog.nedsi.io/fr/about/" hreflang="fr" lang="fr-CH">FR</a></span>
<a class="to-light" href="/set-theme/light/about/" rel="nofollow" title="Light theme, remembered with a cookie"><svg class="icon" viewBox="0 0 24 24" aria-hidden="true" focusable="false">...</svg><span class="vh">Light theme</span></a>
<a class="to-dark" href="/set-theme/dark/about/" rel="nofollow" title="Dark theme"><svg class="icon" viewBox="0 0 24 24" aria-hidden="true" focusable="false">...</svg><span class="vh">Dark theme</span></a>
</p>
</header>
```

- The icons are inline SVG paths (a sun, a crescent moon) with
  `fill`/`stroke` from CSS (`currentColor`). They use no `style`
  attribute and load no external file, so the CSP holds.
- `display: none` removes the hidden link from the accessibility tree.
  A screen reader hears one link, "Light theme" or "Dark theme".
- Without CSS, both links show and both work.
- French: "Thème clair, mémorisé dans un cookie", "Thème sombre", and
  the language block `<a href=".../about/" hreflang="en" lang="en-GB">EN</a>
  <span aria-current="true">FR</span>`.

## Cookie

| Attribute | Value | Why |
| --- | --- | --- |
| Name | `theme` | nginx reads `$cookie_theme`; a `__Secure-` prefix would need a hyphen, which nginx variable names cannot hold |
| Value | `light` only; picking dark deletes the cookie | Only readers who chose light hold a cookie; one value for all of them, so it tells no one apart |
| `Domain` | `nedsi.io` | One choice for the four hosts, all the operator's own; still first-party |
| `Path` | `/` | Every page |
| `Max-Age` | `31536000` (one year) | A preference should outlast the session; a year bounds it |
| `Secure` | set | HTTPS only; plain HTTP is a redirect anyway |
| `HttpOnly` | set | No script reads it; there is no script |
| `SameSite` | `Lax` | Sent when a reader follows a link from another site, so the first page is already in their theme; not sent on cross-site subresource requests |

## Why no banner

- **EU.** Article 5(3) of the ePrivacy Directive
  ([2002/58/EC](https://eur-lex.europa.eu/eli/dir/2002/58/oj)) requires
  consent for storing information on the reader's device, except where
  it is strictly necessary to provide a service the reader explicitly
  requested. The Article 29 Working Party's
  [Opinion 04/2012 on Cookie Consent Exemption](https://ec.europa.eu/justice/article-29/documentation/opinion-recommendation/files/2012/wp194_en.pdf)
  (WP194, section 3.6) names user-interface customisation cookies, such
  as a language or display preference set by the user's explicit
  action, as exempt. For a preference kept beyond the session, it
  treats a visible mention of the cookie at the control as enough. The
  sun's `title` and the privacy page give that mention.
- **Switzerland.** Article 45c of the Telecommunications Act
  ([TCA, SR 784.10](https://www.fedlex.admin.ch/eli/cc/1997/2187_2187_2187/en))
  asks that users are told about the processing and its purpose and
  that they can refuse it. The privacy page does both. The FDPIC's
  [guidelines on cookies](https://www.edoeb.admin.ch/dam/en/sd-web/brLL9rM3ny9d/Leitfaden)
  follow the same line.
- **GDPR and nFADP.** The value is the same for every reader who chose
  light. It identifies no one and is used for nothing but the
  stylesheet.

What would need a banner, and what Requirement 2 therefore forbids:
setting the cookie without the click, any identifier or timestamp in
it, reading it for statistics or anything other than the palette, or
a third party seeing it.

## Privacy page

`site/content/privacy.md`, English. Task 4 writes the French
`privacy.fr.md` as a faithful translation.

The opening paragraph becomes:

> This site runs no script and loads nothing from another site. It
> keeps no statistics. It sets one cookie, and only if you ask for it:
> when you pick the light theme. The only other record of a visit is
> the access log below.

A new section, after "Access logs":

> ## Cookie
>
> Pick the light theme (the sun at the top right) and the site
> remembers it with one cookie:
>
> | Field | Value |
> | --- | --- |
> | Name | `theme` |
> | Value | `light`, nothing else |
> | Set | When you click the sun, never otherwise |
> | Sent to | `nedsi.io` and its subdomains: this blog, the homelab dashboard and the tech radar |
> | Lasts | One year, or until you pick the dark theme, which deletes it |
> | Used for | Sending you the light stylesheet |
>
> It holds no identifier, it is not logged, and no script can read it.
> It is a preference you asked for, and remembering it is all it does,
> so there is no consent banner. To refuse it, don't click the sun. To
> remove it, pick the dark theme or delete this site's cookies in your
> browser.
>
> The language needs no cookie: the French pages are under `/fr/` in
> the address.

"Legal basis" gains one sentence:

> For the cookie: article 45c of the Swiss Telecommunications Act (you
> are told about it here and can refuse it) and, for readers in the
> EU, the exemption in article 5(3) of the ePrivacy Directive for what
> you explicitly ask for.

## Text changes

- Landing page, "What this is": "No newsletter, no cookies, no
  tracking." becomes "No newsletter, no tracking." Task 11 of
  public-website has already removed "(I checked)".
- The dashboard's and the radar's footers link the privacy page in
  their own language.

## Contrast

`scripts/ci/site_contrast.py`, a step of the `site` job, with
`tests/test_site_contrast.py`. It reads both palette files and checks,
in each theme, the WCAG 2.2 contrast ratio
`(L1 + 0.05) / (L2 + 0.05)` of every pair below. It fails on a pair
under its minimum, on a property used in a pair but missing from a
file, and on a property that is in a file but in no pair and not on
the decorative list (`--rule`).

| Foreground | Backgrounds | Minimum | WCAG |
| --- | --- | --- | --- |
| `--fg`, `--muted`, `--link` | `--bg`, `--panel`, `--tile`, `--code-bg` | 4.5 | 1.4.3 |
| `--ok`, `--warn`, `--bad`, `--none` (as text) | `--panel`, `--tile` | 4.5 | 1.4.3 |
| `--syn-*` | `--code-bg` | 4.5 | 1.4.3 |
| `--blip-text` | each `--ring-*` | 4.5 | 1.4.3 |
| `--ring-*` (blips, ring lines) | `--bg` | 3 | 1.4.11 |
| `--ok`, `--warn`, `--bad`, `--none` (accents, bars) | `--panel`, `--tile` | 3 | 1.4.11 |
| `--link` (focus ring), `--fg` (theme icons) | `--bg` | 3 | 1.4.11 |

The dashboard's `TestContrast` reads `assets/theme-dark.css` and
`assets/theme-light.css` instead of `dashboard.css`, and runs its
pairs in both. The tech radar's contrast test does the same with its
copies. The copies are byte-identical, so the three tests agree, and
each module's tests stay self-contained.

## Language

### URL scheme

| Host | English | French |
| --- | --- | --- |
| `nedsi.io` | `/` | `/fr/` |
| `blog.nedsi.io` | `/`, `/about/`, `/privacy/`, `/posts/<slug>/`, `/tags/`, `/tags/<tag>/`, `/index.xml` | `/fr/`, `/fr/about/`, `/fr/privacy/`, `/fr/posts/<slug>/`, `/fr/tags/`, `/fr/tags/<tag>/`, `/fr/index.xml` |
| `homelab.nedsi.io` | `/` | `/fr/` |
| `techradar.nedsi.io` | `/` | `/fr/` |

The operator mentioned the language segment "at the end"
(`/about/fr/`). The prefix is built because it is Hugo's standard
(`defaultContentLanguageInSubdir = false`, so English keeps today's
URLs). It also gives each host one French tree that nginx and the Go
router match with one prefix, and it puts list pages and feeds at
natural paths (`/fr/tags/`, `/fr/index.xml`). The suffix would need
per-page rewrites and odd paths such as `/tags/k8s/fr/`. The prefix
was confirmed on 2026-11-25 and stays unless the operator says
otherwise. If he picks the suffix, task 4 changes the permalinks and
adds `301`s from the prefix paths.

### Head and feeds

On a page with a translation, for example the About page:

```html
<html lang="en-GB">
<link rel="canonical" href="https://blog.nedsi.io/about/">
<link rel="alternate" hreflang="en" href="https://blog.nedsi.io/about/">
<link rel="alternate" hreflang="fr" href="https://blog.nedsi.io/fr/about/">
<link rel="alternate" hreflang="x-default" href="https://blog.nedsi.io/about/">
<link rel="alternate" type="application/rss+xml" href="/index.xml" title="nedsi">
```

The French page has `lang="fr-CH"`, a canonical to itself, the same
three `hreflang` links and `/fr/index.xml`. A republished article keeps
its canonical to the original, and its French translation is
canonical to itself (it is not a copy of the original). A fallback
page has a canonical to the English article, no `hreflang`, and
`sitemap: {disable: true}`.

The feeds: `home.rss.xml` takes `<language>` from the site's locale in
lower case (`en-gb`, `fr-ch`) and lists the regular pages of its
language that have no `fallback`. The dashboard and the radar link the
blog's feed in their language.

### Navigation

`NAV` in `scripts/ci/site_markup.py` becomes one list per language:

| English | French | French target |
| --- | --- | --- |
| Home | Accueil | `https://nedsi.io/fr/` |
| Blog | Blog | `https://blog.nedsi.io/fr/` |
| Homelab | Homelab | `https://homelab.nedsi.io/fr/` from task 5, `https://homelab.nedsi.io/` before |
| Tech radar | Radar techno | `https://techradar.nedsi.io/fr/` from task 6, `https://techradar.nedsi.io/` before |
| About | À propos | `https://blog.nedsi.io/fr/about/` |

The order is that of `NAV` at the time, tech-radar task 3 included.
French link texts are longer, so `layout-check.sh` compares pages of
one language with each other.

### Blog

- `site/hugo.toml`: `defaultContentLanguage = "en"`,
  `defaultContentLanguageInSubdir = false`, and `[languages.en]` and
  `[languages.fr]` with their locale (`en-GB`, `fr-CH`), language name,
  weight, title and `params.description`, using the keys of the pinned
  Hugo (0.169.0). Translation by file name: `index.fr.md` next to
  `index.md`, and `privacy.fr.md`. A translation keeps the English tags,
  so tag paths match.
- `site/i18n/en.yaml` and `fr.yaml`: every string the layouts print
  (nav, footer, the preferences, "Tags", dates through `time.Format
  ":date_long"` with the language's locale, the fallback note, the 404
  text). `hugo --printI18nWarnings` in the build fails on a missing key.
- The layouts take the toggle target from `.Translations`, and the
  `hreflang` links only when neither side has `fallback`.
- **Fallback pages.** An article with no translation has a stub
  `index.fr.md` with front matter `fallback: true` and the English
  `title`, `date` and `summary`. Its layout prints the French chrome,
  the note "Cet article n'existe pour l'instant qu'en anglais." with a
  link to the English page, then the English page's `.Content` in
  `<div lang="en-GB">`. The stub is a translation in Hugo's sense, so
  the toggles and the French home list work with no special case. `task
  site:fallback -- <bundle>` writes the stub, and the build check fails
  when an article has neither file or a stub's fields differ from the
  English ones. Rejected: Hugo's sites matrix and complements (0.153).
  They can fill in missing translations without stubs, but they are new
  and the Hugo forum reports open problems filling in missing
  translations (November 2026). The stub is explicit, and CI checks it.
- Today the blog has no published article (`site/content/` holds About
  and privacy). The rule applies from the first article on: it ships
  with a translation or a stub.

### Landing page

`apps/website/landing/index-fr.html`: the French text of `index.html`,
the French nav and toggles. It is a key of `website-landing`, served at
`/fr/` (see [nginx](#nginx)).

### Dashboard

- `dashboard/internal/web/i18n.go`: `type catalogue map[string]string`
  for `en` and `fr`, the month names, and `formatPercent` and
  `formatNumber` per language. French uses a decimal comma, U+202F
  before `%` and before units, and the same half-to-even rounding to two
  decimals as English (homelab-dashboard Requirement 11), so 99.957
  shows "99,96 %". Dates use the form `25 novembre 2026, 14:05`, Zurich
  time.
- `pageData` gains `Lang` (`en-GB` or `fr-CH`), `T` (the catalogue)
  and the URLs of both language versions. The templates print
  `{{index .T "availability.heading"}}`, and `html/template` escapes as
  before. `/fr/` renders with `fr`, and `/fr` redirects to `/fr/`.
  `/snapshot.json` stays language-neutral.
- `TestCatalogue`: both languages have the same keys, no value is
  empty, and no value holds U+2014 or the word "bot". There are golden
  pages for `/fr/` (full snapshot and not found), and the
  screenshot check covers both languages.

### Tech radar

- `techradar/entries.yaml` gains a required `reason_fr`, validated like
  `reason` (one line, at most 140 characters, no em dash, the deny
  list).
- `techradar/internal/radar/i18n.go` holds the page strings, the
  quadrant names (Techniques, Outils et langages, Plateforme,
  Infrastructure) and the ring names (Adopter, Essayer, Évaluer,
  Suspendre), with the same catalogue test. The blip `<title>` uses
  the French ring name.
- The generator renders `index.html` and `index-fr.html` from one
  placement, so the blips sit in the same place in both languages.

## Translation

Pages translated in this spec, as of 2026-11-25:

| Host | Pages |
| --- | --- |
| `nedsi.io` | the landing page |
| `blog.nedsi.io` | the home list, About, privacy, the tag list and term pages, 404, the footer, the RSS channel's title and description |
| `homelab.nedsi.io` | the page (every heading, label, tooltip, the intro, the DORA, Supply chain and Security texts, "Coming later"), the not-found page |
| `techradar.nedsi.io` | the page, the intro, the legend, every entry's `reason_fr` |

Conventions:

- Swiss French (`fr-CH`): "septante" and "nonante" where a number is
  spelled out (digits elsewhere), Swiss usage over French usage where
  they differ, and "vous" for the reader, the usual register of a
  public site in Romandy. The operator can switch to "tu" with one
  instruction.
- The operator's voice as in the English text: the same jokes, the same
  asides, the same length. A translation of validated text, not a
  rewrite.
- French typography: a no-break space (U+00A0) before `:` and inside
  `« »`, a narrow no-break space (U+202F) before `;`, `!`, `?` and `%`.
- No em dash (U+2014). "Agents", never "bots" or "robots".
- Technical terms that French-speaking engineers use in English stay in
  English (cluster, pull request, homelab, GitOps, SLO). Product
  names, commands, code and paths do not change.
- Agents draft the French. The review round checks fidelity, voice and
  the conventions. Article translations open as draft PRs, which only
  the operator marks ready (public-website Requirement 2.5).

## Checks

| Check | Where | What |
| --- | --- | --- |
| `site_markup.py` | `site` job, dashboard golden pages, radar page | the preferences markup and its targets; `lang`, canonical, `hreflang` per Requirement 4.5; `NAV` per language; no colour literal outside the palette files; the text rules on French pages too |
| Translation check (`site_markup.py --content`) | `site` job | every English page has a `.fr.md` translation or (articles only) a stub; every French file has an English original; stub fields equal |
| `site_contrast.py` | `site` job | [Contrast](#contrast) |
| `site-check.sh` copy check | `site` job | the palette copies equal `site/assets/css/theme-*.css` |
| `site-serve-check.sh` | `site` job | the nginx cases of Requirement 5.1 against the real `nginx.conf` and `theme.conf` |
| PostSync smoke (`apps/website/kustomization.yaml`) | after every sync | the same cases through the Gateway, for each nginx host |
| `layout-check.sh` | `site` job | `.prefs` measured with `nav.site`; pages compared within one language |
| Go tests | `dashboard` and `techradar` jobs | the handlers' cases, `TestContrast` in both themes, `TestCatalogue`, golden pages in both languages |

## Why it is like this

- **A stylesheet that varies, not HTML that varies.** A class on
  `<html>` set per request (nginx SSI or `sub_filter`, a Go template)
  makes every page vary by cookie. The blog would lose its
  `max-age=300` caching and ETags, and nginx would parse every page.
  Swapping one small stylesheet keeps the HTML static and identical.
- **Rejected:** `prefers-color-scheme` alone (no toggle, and the
  operator wants dark by default); `<link rel="alternate stylesheet">`
  (only Firefox offers a menu, and nothing persists); a CSS checkbox
  (`:has(:checked)`), which forgets the choice on the next page; a
  `?theme=` parameter on every link, which breaks canonical URLs and
  every inbound link; a flip endpoint (`/toggle-theme`), which a
  repeated request or a prefetch would undo, while an explicit target
  is idempotent.
- **The language in the path, not in a cookie.** One URL shows the
  same page to everyone, so feeds, `hreflang`, crawlers and caches work.
  There is also no second cookie to explain.
- **One palette for all hosts.** The four sites already shared the
  blog's dark values. One pair of files, one contrast check and
  byte-checked copies keep them from drifting.
