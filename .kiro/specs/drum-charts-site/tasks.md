# Tasks: drum-charts-site

One PR per task, in order; each names its repository. Task 6 waits for
site-theme-language task 4 and the operator's French corrections, and
tasks 7 and 8 do not wait for task 6. Each task merges after its review round and is checked
live where it changes a public page (operator, 2026-11-24: no approval
pauses). In this repository, merges go through `scripts/pr-merge.sh`;
in ned-si/drum-charts, a squash merge on a green `build`, signed
commits. No task writes to the cluster outside Argo CD. Before each
merge, rebase on `main`; when another open pull request changes the same
lines (the shared nav, `site_markup.py`, `layout-check.sh`), wait for it
to merge and rebase. Defaults: [requirements.md](requirements.md#decided-defaults).

- [ ] 1. Site data and its image (**ned-si/drum-charts**):
      `scripts/site-data.py`, `site-data.Dockerfile`, `make site-data`;
      in `build.yaml` the tag output of `charts`, the site-data step and
      its artifact, the release job on that tag, the `site-data` job
      ([design, Workflow](design.md#workflow)); the README (Layout, CI,
      and in Naming the rule that `title` is the artist and `subtitle`
      the song). After the merge: the operator sets the GHCR package
      `drum-charts` to public. Check: `build` green on the pull request
      and on `main`; `cosign verify` of `:main` with the drum-charts
      identity; an anonymous `docker pull` of it; its `/charts/` holds
      15 PDFs, 25 page images and `charts.json`, and no `.mp3`;
      acceptance criterion 13 on a throwaway branch, deleted after.
      [1]
- [ ] 2. Generator and CI (**ned-si/homelab**, not live): the
      `drumcharts/` module (validation, allow-list, templates, the
      English catalogue, fixture, golden pages), `drumcharts/source.yaml`
      with the digest of task 1, `scripts/ci/drumcharts-data.sh`,
      `scripts/ci/drumcharts-check.sh` and the `drumcharts` job in the
      `ci` job's `needs:`; in `site_markup.py` `charts.nedsi.io` in
      `SITE_HOSTS` and `THEMED`, the two `LINKS` and the media rule,
      with their tests; the copies in `site-check.sh` and
      `task site:layout-sync`; the Renovate rule. Check: acceptance
      criteria 4-7; the real render read at 390 and 1920 px in both
      themes, locally. [2.1, 2.2, 2.4, 3, 4.1, 4.4, 4.5, 8]
- [ ] 3. The site image carries the charts (**ned-si/homelab**, not
      served): `site-publish.yaml` (paths, Go, cosign, verify, render),
      `site/Dockerfile`, `.gitignore`, the image smoke test's file check.
      Then the `homelab-site` digest pull request deploys it with no
      visible change. Check: `site-publish` green; the deployed digest's
      `/usr/share/nginx/charts/` holds `index.html` and one directory
      per song (`docker create` and `docker cp` of that digest); the
      website PostSync smoke passes. [2.3]
- [ ] 4. Serving at `charts.nedsi.io` (**ned-si/homelab**, live).
      Operator first: no unowned `charts` record in the `nedsi.io` zone.
      The certificate, the two listeners, the HTTPRoute hostnames, the
      nginx server block and map entry, the probe and SLO rules with
      their tests, the `docs/sre.md` row, the pentest scope, the serve
      check, the PostSync smoke and the image smoke cases of
      [design, Checks](design.md#checks), `scripts/charts-check.sh`,
      `task render`. Check: acceptance criteria 1, 2, 3 and 8 live.
      [3.4, 4.2, 4.3, 5]
- [ ] 5. Links (**ned-si/homelab**, live): "Charts" in `NAV` and the
      navigation bars of the blog, the landing page, the dashboard, the
      tech radar and the charts site, with the golden pages and
      screenshots; the landing page's overview item and card link; the
      privacy page's "Sent to" row; the charts pages in
      `layout-check.sh`; the site-theme-language lines this spec
      supersedes. If site-theme-language task 4 has merged, the French
      nav label, landing text and privacy row first go to the operator
      for review. Then the `homelab-site` and dashboard image deploys.
      Check: acceptance criteria 9-11 live. [3.7, 6.1-6.4]
- [ ] 6. French at `charts.nedsi.io/fr/` (**ned-si/homelab**, live),
      after site-theme-language task 4: the strings of
      [design, Strings](design.md#strings) proposed to the operator in
      two columns, then the `fr` catalogue with his corrections, the
      `fr/` tree, the toggle, `hreflang` and canonical, `TestCatalogue`,
      the golden pages in French, the French `NAV` target for Charts.
      Check: acceptance criterion 14 live. [7]
- [ ] 7. Docs (**ned-si/homelab**): `docs/drum-charts.md`;
      `docs/website.md` (the host, the copies, the generator); the README
      Services table, the public pages line and the layout table;
      `docs/networking.md` (the name); the `drumcharts/` row in
      `.kiro/steering/structure.md`. Check: a newcomer can tell from the
      docs alone how a new chart reaches the site and how to see that the
      site is current; links resolve. [6.5]
- [ ] 8. Link the site from drum-charts (**ned-si/drum-charts**): the
      README's Songs section points to `https://charts.nedsi.io/`. Its
      merge is the end-to-end test. Check: acceptance criterion 12.
      [2.1, 2.3]

The last task ticked sets `status: done`, `closed:`, and closes #1761.
