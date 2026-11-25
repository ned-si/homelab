---
kind: change
status: active
created: 2026-11-25
issue: 1662
---
# Requirements: site-theme-language

## Introduction

Every public page on a `nedsi.io` name gets two choices at the top
right of the navigation bar: a light or a dark theme, and English or
French. The pages are the landing page (`nedsi.io`), the blog with its
About, privacy, tag and 404 pages (`blog.nedsi.io`), the dashboard
(`homelab.nedsi.io`) and the tech radar (`techradar.nedsi.io`).

The operator asked for the blog in English and French on 2026-11-24
(#1662) and widened it on 2026-11-25 to every page, together with light
and dark themes. Both keep the site's promises: no JavaScript, the
strict CSP, no third-party resource, and no consent banner.

- The theme is a link to a small endpoint on the same host. It sets
  one first-party preference cookie, only when the reader clicks, and the
  server returns the matching palette stylesheet.
- The language is in the URL: the French page is the English path
  under `/fr/`. It needs no cookie.

Non-goals are listed under [Out of scope](#out-of-scope).

## Glossary

- **Public pages**, **shared layout**, **navigation bar**: as defined in
  the [public-website spec](../public-website/requirements.md#glossary).
- **Host**: one of `nedsi.io`, `blog.nedsi.io`, `homelab.nedsi.io`,
  `techradar.nedsi.io`. The first two and the tech radar are static
  files served by the `website` nginx pod; the dashboard is the Go web
  role of `homelab-dashboard`.
- **Theme**: `dark` (the default) or `light`.
- **Palette**: the two stylesheets `theme-dark.css` and
  `theme-light.css`, which hold every colour of every public page as
  custom properties, defined once in `site/assets/css/`
  ([design, Palette](design.md#palette)).
- **Theme stylesheet**: `/theme.css` on every host, whose body is the
  dark or the light palette, chosen by the server from the cookie.
- **Theme endpoint**: `GET /set-theme/<theme><path>` on every host. It
  stores the choice and redirects to `<path>`.
- **Theme cookie**: `theme=light`, the only cookie on any public page
  ([design, Cookie](design.md#cookie)).
- **Preferences**: the `<p class="prefs">` block at the top right of
  `header.site`, holding the language toggle and then the theme toggle.
- **Translation**: the French version of a page, at the same path under
  `/fr/`.
- **Fallback page**: the French address of an article that has no
  translation yet. It shows the English text with a note in French.
- **Message catalogue**: the English and French strings of a Go page
  (the dashboard, the tech radar), keyed by name, with a test that both
  languages define every key.

## Requirement 1: Two themes, chosen without JavaScript

**User story:** As a reader, I want a light or a dark page, and the
choice to stay as I move between the blog, the dashboard and the radar.

1. EVERY public page SHALL render in the dark theme when the request
   carries no theme cookie, whatever the reader's system setting.
2. EVERY public page SHALL carry, in its preferences, two theme links: a
   sun to `/set-theme/light<path>` and a moon to `/set-theme/dark<path>`,
   where `<path>` is the page's own path (a 404 page uses its
   language's home, `/` or `/fr/`). The
   palette hides the link to the theme already shown, so the reader sees
   one icon, the sun in the dark theme and the moon in the light one.
   Each link has a visible focus ring and an accessible name ("Light
   theme" or "Dark theme", in French "Thème clair" or "Thème sombre").
   Its `title` says that the choice is remembered with a cookie.
3. THE theme endpoint SHALL answer `303` with a relative `Location:
   <path>`, and SHALL set the theme cookie for `light` or delete it for
   `dark`. A path made of anything other than letters, digits, `.`,
   `_`, `~`, `-` and `/`, or any theme other than `light` and `dark`,
   SHALL get `404` and set nothing. The `Location` SHALL always start
   with exactly one `/`, so the endpoint never redirects to another
   host.
4. EVERY public page SHALL link `/theme.css` after its own stylesheet.
   `/theme.css` SHALL return the light palette when the request carries
   `theme=light`, and the dark palette otherwise. It SHALL return it with
   `Cache-Control: no-store` and `Vary: Cookie`, so the choice shows on
   the next page load.
5. THE HTML of a page SHALL NOT depend on the theme. The two themes
   differ only in the body of `/theme.css`, so page caching and ETags
   stay as they are.
6. THE palette files SHALL hold only custom properties, `color-scheme`
   and the rules that hide one theme link. No other stylesheet SHALL
   hold a colour literal. Layout therefore never depends on the theme.
7. THE theme SHALL work the same way on every host: nginx for
   `nedsi.io`, `blog.nedsi.io` and `techradar.nedsi.io`, the Go web role
   for `homelab.nedsi.io` ([design, Per host](design.md#per-host)).
8. THE endpoint, the stylesheet and the toggle SHALL keep
   public-website Requirement 3, except its "no cookie" line
   ([Supersedes](#supersedes)): no JavaScript, no inline style, the
   same CSP and headers, `GET` and `HEAD` only.

## Requirement 2: The cookie needs no consent banner

**User story:** As the operator, I want the theme choice to stay within
the GDPR, the ePrivacy rules and the Swiss nFADP and TCA, with no
consent banner.

1. THE theme cookie SHALL be set only in the response to the reader's
   click on the sun. No page, stylesheet, redirect or error SHALL set it
   otherwise.
2. ITS value SHALL be `light`, with no identifier, no timestamp and
   nothing that tells one reader from another. Its attributes SHALL be
   those of [design, Cookie](design.md#cookie): `Domain=nedsi.io`,
   `Path=/`, `Max-Age=31536000`, `Secure`, `HttpOnly`, `SameSite=Lax`.
3. THE servers SHALL read it only to choose the palette. No log line,
   metric, statistic or snapshot SHALL record it or the `Cookie` header.
4. THE privacy page SHALL describe it with the text of
   [design, Privacy page](design.md#privacy-page): its name, value,
   when it is set, where it is sent, how long it lasts, what it is used
   for, why there is no banner and how to refuse or delete it.
5. THE landing page SHALL no longer say "no cookies". Its line becomes
   "No newsletter, no tracking." ([design, Text changes](design.md#text-changes)).

## Requirement 3: Both themes meet WCAG 2.2 AA

**User story:** As a reader with low vision, I want every text and
status to stay readable in both themes.

1. IN each theme, every text colour SHALL have a contrast of at least
   4.5:1 against every background it is used on, and every non-text
   colour that carries meaning (status accents, chart bars and lines,
   radar rings and blips, the focus ring, the theme icons) at least
   3:1 (WCAG 2.2 1.4.3 and 1.4.11).
2. ONE contrast check SHALL test both palette files against the pairs
   of [design, Contrast](design.md#contrast) in the `site` job. The
   dashboard's `TestContrast` and the tech radar's contrast test SHALL
   run on both themes from their copies.
3. A pair added to the palette without a row in the check's table
   SHALL fail the check.

## Requirement 4: English and French

**User story:** As a French-speaking reader, I want every page in
French, and a link back to English on each one.

1. ENGLISH SHALL stay the default at the current URLs. The French
   version of every page SHALL be the same path under `/fr/`, for
   example `https://blog.nedsi.io/fr/about/`, `https://nedsi.io/fr/`,
   `https://homelab.nedsi.io/fr/` and `https://techradar.nedsi.io/fr/`.
   There SHALL be no redirect by `Accept-Language` and no language
   cookie.
2. EVERY public page SHALL carry a language toggle in its preferences,
   left of the theme toggle: "EN" and "FR", the current language as
   text with `aria-current="true"`, the other a link to the same page in
   that language with `hreflang` and `lang` set.
3. THE navigation bar of a French page SHALL link the French version of
   each host once that host serves French
   ([design, Navigation](design.md#navigation)). Its link texts are
   Accueil, Blog, Homelab, À propos and Radar techno.
4. `<html lang>` SHALL be `en-GB` on English pages and `fr-CH` on French
   ones. A fallback page keeps `fr-CH` and marks the English text with
   `lang="en-GB"`.
5. EVERY page that has a translation SHALL carry `<link rel="alternate"
   hreflang="en">`, `hreflang="fr"` and `hreflang="x-default"` (the
   English URL), all absolute. Its `<link rel="canonical">` SHALL be its
   own URL in its own language. A republished article keeps its
   canonical to the original, and its translation points to its own URL.
   A fallback page carries no `hreflang`, and its canonical is the
   English article.
6. THE blog SHALL publish one feed per language: `/index.xml`
   (`<language>en-gb</language>`, the English articles) and
   `/fr/index.xml` (`<language>fr-ch</language>`, the French
   translations only). Every page links the feed of its own language.
7. THE French text of every existing page SHALL be written in Swiss
   French and in the operator's voice, with no em dash and "agents",
   never "bots". This covers the landing page, the blog home, About,
   privacy, the tag pages, 404, the dashboard and the tech radar,
   including every entry's reason. The scope and the conventions are in
   [design, Translation](design.md#translation).
8. AN article with no translation SHALL have a fallback page at its
   French address: the French navigation, a note in French that the
   article is only in English for now with a link to it, then the
   English text. The French blog home SHALL list it with the same note.
9. THE dashboard and the tech radar SHALL render French from a Go
   message catalogue. Numbers, percentages and dates SHALL follow
   `fr-CH` (`99,96 %`, `25 novembre 2026`). A test SHALL fail when a key
   is missing in one language or a French string holds an em dash.
10. CI SHALL fail when an English page has neither a translation nor a
    fallback page, when a French page has no English original, or when
    a page's `hreflang`, canonical, `lang` or toggle links differ from
    Requirement 4.

## Requirement 5: The checks

**User story:** As the operator, I want CI and the live smoke to prove
both choices, so a later change cannot quietly break them.

1. `scripts/ci/site-serve-check.sh` and the website PostSync smoke SHALL
   test, on each nginx host:
   - `/theme.css` with and without `Cookie: theme=light` (the body, the
     two headers);
   - `/set-theme/light/` (`303`, the `Location`, every cookie attribute);
   - `/set-theme/dark/` (the delete);
   - `/set-theme/blue/`, a path with `%5c` and a path with `%0d%0a`
     (`404`, no `Set-Cookie`), and `/set-theme/light//example.com/`
     (no `Location` starting with `//`);
   - `/fr/` (`200`).
2. THE dashboard's web tests SHALL cover the same cases on its handler,
   plus the golden pages in both languages.
3. `scripts/ci/layout-check.sh` SHALL measure the preferences block
   with the nav and compare pages of the same language. Switching the
   theme SHALL not move anything, because the palette holds no layout.
4. `scripts/ci/site_markup.py` SHALL check, on every rendered page, the
   preferences markup, the theme link targets and Requirement 4.10.

## Non-functional requirements

- No new pod, image, dependency outside the Go standard library, or
  third-party resource.
- Size: each palette file under 4 KiB, so fetching it on every page
  costs nothing noticeable.
- Language: English pages in British English; French pages in Swiss
  French. Reference text (privacy page, dashboard, radar reasons)
  follows the documentation standard; the landing page, About, the blog
  home and articles follow the operator's voice.

## Acceptance criteria

1. `curl -sI https://blog.nedsi.io/theme.css` shows `Cache-Control:
   no-store` and `Vary: Cookie`. `curl -s` of it holds
   `color-scheme: dark`; with `-H 'Cookie: theme=light'` it holds
   `color-scheme: light`. The same on `nedsi.io`, `homelab.nedsi.io` and
   `techradar.nedsi.io`. [1.1, 1.4, 1.7]
2. `curl -sI https://blog.nedsi.io/set-theme/light/about/` returns `303`,
   `Location: /about/` and `Set-Cookie: theme=light; Domain=nedsi.io;
   Path=/; Max-Age=31536000; Secure; HttpOnly; SameSite=Lax`.
   `/set-theme/dark/about/` returns `303` with `Max-Age=0`.
   `/set-theme/blue/` and `/set-theme/light/%5cexample.com/` return
   `404` with no `Set-Cookie`. `/set-theme/light//example.com/` returns
   `404`, or `303` with `Location: /example.com/` on the same host (nginx
   merges slashes), never a `Location` starting with `//`. [1.3, 2.1,
   2.2]
3. `curl -sI` of any page, the theme stylesheet or a `404`, without the
   endpoint, carries no `Set-Cookie`. [2.1]
4. The contrast check passes on both palettes and fails in a throwaway
   commit that sets the light `--muted` to `#9aa0a6`. [3.1-3.3]
5. `curl -s https://blog.nedsi.io/fr/about/` has `<html lang="fr-CH">`,
   the three `hreflang` links and a canonical to itself. Its toggle links
   `https://blog.nedsi.io/about/`, and its nav links the French version
   of each host. [4.1-4.5]
6. `https://blog.nedsi.io/fr/index.xml` is valid RSS with `<language>fr-ch</language>`.
   [4.6]
7. `curl -s https://homelab.nedsi.io/fr/` shows its percentages as
   `99,96 %` (narrow no-break space) and its section headings in French;
   `go test ./...` passes the catalogue test. [4.9]
8. The privacy page, in both languages, holds the cookie table of the
   design. [2.4]
9. The checks of Requirement 5 pass in `ci` and in the PostSync smoke.
   [5.1-5.4]

## Out of scope

- A third language, machine translation, and translating the
  repository's documentation.
- Following the reader's system theme (`prefers-color-scheme`) when no
  cookie is set: the operator chose dark as the default (2026-11-25).
- Redirects by `Accept-Language` or by IP country.
- Translating article URLs (slugs): the French path is the English one
  under `/fr/`.
- Themes or languages for the household services on `lilalala.com`.

## Supersedes

These lines of other specs stop holding when the task named here
merges, and that task edits them to point here:

| Spec and line | Becomes | Task |
| --- | --- | --- |
| public-website Requirement 3.1, "set no cookie" | No cookie other than the theme cookie of this spec | 1 |
| public-website, Out of scope, "a second language"; Language, "English, British spelling" | French as in this spec | 4 |
| homelab-dashboard Requirement 9, "the site's dark palette"; Decided defaults, Theme, "Always dark ... no light variant"; design, "Always dark" | Dark by default, light on the reader's choice, the palette of this spec | 2 |
| homelab-dashboard, Language, "English, British spelling" | English and French as in this spec | 5 |
| tech-radar, Language, "English, British spelling" | English and French as in this spec | 6 |

## Decided defaults

| Topic | Default | Reason |
| --- | --- | --- |
| Scope | Every public page on the four hosts (operator, 2026-11-25) | One site, one set of choices |
| Default theme | Dark when no cookie is set, whatever the system setting (operator, 2026-11-25) | The operator's choice; one first paint for everyone |
| Mechanism | A link to `/set-theme/<theme><path>` that sets the cookie and redirects; the server picks the body of `/theme.css` from the cookie ([design](design.md#how-the-theme-is-served)) | No JavaScript; the HTML stays identical in both themes and keeps its caching |
| Cookie | `theme=light`, set on the click only, deleted when dark is picked, `Domain=nedsi.io`, one year, `Secure`, `HttpOnly`, `SameSite=Lax` | One cookie for all four hosts; only readers who chose light hold one; nothing to identify a reader |
| Consent | No banner ([design, Why no banner](design.md#why-no-banner)) | A preference the reader explicitly asks for, strictly necessary to remember it, described on the privacy page with how to refuse it |
| URL scheme | The `/fr/` prefix (`https://blog.nedsi.io/fr/about/`), Hugo's standard. The operator once mentioned the segment "at the end" (`/about/fr/`); the prefix was confirmed on 2026-11-25 and stays unless he says otherwise | Works with `hreflang`, one French tree per host, nginx and the Go router match it with one prefix |
| Language memory | None: the URL is the language; no cookie, no `Accept-Language` redirect | No second cookie; every URL shows the same page to everyone, which crawlers and caches need |
| French | Swiss French (`fr-CH`), the operator's voice, no em dash, "agents" | The operator's language and the site's text rules |
| Untranslated articles | A fallback page per article, generated from a stub `index.fr.md` with `fallback: true` ([design, Blog](design.md#blog)) | Explicit, works on the pinned Hugo, checked by CI; the language toggle always has a target |
| French feed | French translations only | A French feed holds French text; English readers have `/index.xml` |
| Go strings | A message catalogue in each module, standard library only | The dashboard's "standard library first"; a test keeps both languages complete |
| Merge | Each task merges after its review round and is checked live (operator, 2026-11-24: no approval pauses); French article translations follow public-website Requirement 2.5 (draft PR, the operator marks it ready) | Pages translate text he has validated; articles are his words under his name |
