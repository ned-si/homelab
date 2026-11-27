# Tasks: site-theme-language

One PR per task, in order: the theme first, then the language. Task 1
starts once public-website task 12 (the shared layout) has merged.
Each task merges after its review round and is checked live (operator,
2026-11-24: no approval pauses). No task writes to the cluster outside
Argo CD. Defaults: [requirements.md](requirements.md#decided-defaults).

## Theme

- [x] 1. Theme on `nedsi.io` and `blog.nedsi.io` (**live**): the
      palette files `site/assets/css/theme-dark.css` and
      `theme-light.css` with every property of
      [design, Palette](design.md#palette) except `--ring-*` and
      `--blip-text` (task 3 adds them); their landing copies and
      `task site:layout-sync`; `main.css`, `syntax.css` (hand-kept
      `var(--syn-…)` rules, [design, Syntax colours](design.md#syntax-colours)),
      `landing.css` and `layout.css` on variables only; the
      preferences markup with the theme links (no language toggle yet)
      in `baseof.html`, `404.html` and the landing page; the `.prefs`
      rules in `layout.css`; `nginx.conf` maps and `apps/website/theme.conf`
      in the `website-nginx` ConfigMap, with the `Sec-Fetch-Site` and
      `Sec-Purpose` rule and `error_page 404 $not_found`; `robots.txt` with
      `Disallow: /set-theme/`; `site_contrast.py` and its test;
      `site_markup.py` (preferences, no colour literal);
      `layout-check.sh` (`.prefs`); `site-serve-check.sh` and the
      PostSync smoke; the privacy page and the landing line of
      [design, Text changes](design.md#text-changes); the
      public-website lines this spec supersedes (Requirement 3.1).
      Then the `homelab-site` digest bump. Check: acceptance criteria
      1-4 and 8 (English) live on both hosts; a manual click on the sun
      and the moon in a browser at 390 and 1920 px; the Hubble check of
      [design, Gateway](design.md#gateway), recorded in the design, with
      its issue and the narrowed privacy text if the flows hold
      headers. [1, 2, 3, 5.1, 5.3, 5.4]
      Theme #1715, publish smoke #1725, image #1728 (`homelab-site`).
      Checked live on both hosts with curl; the Hubble check and the
      browser click are #1735.
- [x] 2. Theme on `homelab.nedsi.io` (**live**): the embedded palette
      copies; `dashboard.css` without its palette; `/theme.css` and
      `/set-theme/` in `public.go` with their tests (the
      `Sec-Fetch-Site` and `Sec-Purpose` cases included); the preferences in
      `layout.html` (page and not found); no `color-scheme` meta;
      `TestContrast` on both themes; golden pages and screenshots in
      both themes; the copy in the copy check; the homelab-dashboard
      lines this spec supersedes (Introduction item 1, Requirement 3.9,
      Theme, the design's "Always dark"). Then the dashboard image
      deploy. Check: acceptance criteria 1-3 live on
      `homelab.nedsi.io`. [1.1-1.8, 3.2, 5.2]
      Theme #1716, image #1730 (`homelab-dashboard`). Checked live with
      curl; the browser click is #1735.
- [x] 3. Theme on `techradar.nedsi.io` (**live**): the generator writes
      the palette copies from `techradar/internal/radar/assets/` and the
      preferences; `--ring-*` and `--blip-text` join
      `site/assets/css/theme-*.css` with the values of `techradar.css`,
      with their contrast rows, and leave `techradar.css`; the radar
      copies in the copy check; the tech-radar design lines this spec
      supersedes (The page, Ring colours); the
      `techradar.nedsi.io` server block includes `theme.conf`; the
      radar's contrast test on both copies; the serve and smoke cases
      for the host. Needs tech-radar task 2 (serving). If a tech-radar
      PR already did all of this, tick this task with that PR. Check:
      acceptance criteria 1-3 live on `techradar.nedsi.io`. [1.1-1.8,
      3.2, 5.1]
      Theme #1717. Checked live with curl; the browser click is #1735.

## Language

- [x] 4. French on `nedsi.io` and `blog.nedsi.io` (**live**):
      `hugo.toml` languages; `site/i18n/en.yaml` and `fr.yaml`; the
      French About, privacy, home, tags and 404, and
      `apps/website/landing/index-fr.html`, per
      [design, Translation](design.md#translation); the language toggle
      on both hosts; `hreflang`, canonical, `lang` and `/fr/index.xml`;
      the fallback layout and `task site:fallback`; the nginx `/fr/`
      locations; `NAV` per language and the translation check in
      `site_markup.py`; `layout-check.sh` per language;
      `site-serve-check.sh` and the smoke on `/fr/`; the public-website
      lines this spec supersedes (Out of scope, Language, Requirements
      7.3 and 7.4). Then the
      `homelab-site` digest bump. Check: acceptance criteria 5, 6 and 8
      live. [4.1-4.8, 4.10, 5.1, 5.3, 5.4]
      French #1743, blog smoke #1744, image #1796 (`homelab-site`).
      Checked live with curl: `nedsi.io/fr/` and the blog's `/fr/`,
      `/fr/about/`, `/fr/privacy/` and `/fr/index.xml` return 200; the
      PostSync smoke passed.
- [x] 5. French on `homelab.nedsi.io` (**live**): `i18n.go` with the
      catalogue, `formatPercent` and dates; the `/fr/` route; the
      language toggle and `hreflang` in `layout.html`; `TestCatalogue`;
      golden pages and screenshots for `/fr/`; the French `NAV` target
      for Homelab; the homelab-dashboard line this spec supersedes
      (Language). Then the dashboard image deploy. Check:
      acceptance criterion 7 live. [4.1-4.5, 4.9, 5.2]
      French #1763, image #1838 (`homelab-dashboard`). Checked live:
      `homelab.nedsi.io/fr/` has `lang="fr-CH"` and French headings.
- [x] 6. French on `techradar.nedsi.io` (**live**): `reason_fr` on every
      entry and its validation; the radar catalogue; `index-fr.html`
      and its nginx location; the language toggle and `hreflang`; the
      French `NAV` target for the radar; the tech-radar line this spec
      supersedes (Language). Check: `/fr/` live with every reason in
      French; the generator's tests. [4.1-4.5, 4.7, 4.9]
      French #1747. Checked live: `techradar.nedsi.io/fr/` returns 200
      with the French radar.

## Docs

- [x] 7. Docs: `docs/website.md` (the theme contract, the palette and
      where its copies live, the cookie, how to add a translation or a
      stub, the conventions of [design, Translation](design.md#translation),
      Why it is like this); `docs/techradar.md` (`reason_fr`); the
      dashboard's doc (the catalogue). Check: a newcomer can add a
      palette colour and a French page from the docs alone; links
      resolve.
      Docs #1860.

## Changes

- [x] 8. Language switch shows only the inactive language (operator,
      2026-11-26): one `<a class="lang">` with `aria-label` "Français"
      or "English" on the four hosts, no underline (`.prefs a` in
      `layout.css` and its copies); `site_markup.py` and its test; the
      dashboard and radar golden pages; Requirement 4.2 and
      [design, Markup](design.md#markup). Then the `homelab-site` and
      `homelab-dashboard` digest bumps. Check: the single link live on
      the four hosts, both languages, both themes, at 1920x1080 and
      390x844. [4.2] (#1857)
      Switch #1859.

The last task ticked sets `status: done`, `closed:`, and closes #1662.
