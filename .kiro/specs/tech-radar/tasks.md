# Tasks: tech-radar

One PR per task, in order. Task 1 starts once public-website task 12
(the shared layout) has merged. Each task merges after its review round
and is checked live where it changes a public page (operator,
2026-11-24: no approval pauses). No task writes to the cluster outside
Argo CD. Defaults: [requirements.md](requirements.md#decided-defaults).

- [x] 1. Generator and data (**not live**): the `techradar/` module
      (`cmd/techradar`, `internal/radar` with validation, placement, the
      SVG builder and the page template),
      `techradar/entries.yaml` with the
      [design's inventory](design.md#inventory), the rendered
      `apps/website/techradar/` (not yet in the kustomization), the
      `techradar` CI job with `scripts/ci/techradar-check.sh` in the
      `ci` job's `needs:` ([design, CI](design.md#ci)),
      `techradar.nedsi.io` in `SITE_HOSTS` of `site_markup.py`, the
      Renovate rule, the deny-list hook path. Check: acceptance criteria 2-5 and 8; the rendered page
      read at 390 and 1920 px in the PR's screenshots. [1, 2, 3.1, 3.4,
      5]
      #1687. Screenshots at 390 and 1920 px were read locally, not
      attached to the PR.
- [x] 2. Serving at `techradar.nedsi.io` (**live**). Operator first: no
      unowned `techradar` record in the `nedsi.io` zone. The
      certificate, the two listeners, the HTTPRoute hostnames, the
      nginx server block and map entry, the `website-techradar`
      ConfigMap and its mount, the probe and SLO rules with their tests,
      the `docs/sre.md` row, the pentest scope, the serve and smoke
      checks, `task render`. Check: acceptance criteria 1 and 6 live.
      [3.2, 3.3, 4.1, 4.2]
      #1688. The smoke sends the 404 and 405 to the Service, as for the
      other sites.
- [ ] 3. Links (**live**): "Tech radar" in `NAV` and the navigation
      bars of the blog, the landing page, the dashboard and the radar;
      the landing page's overview line and card; the radar page in
      `scripts/ci/layout-check.sh`. Then the `homelab-site` digest bump
      and the dashboard image deploy. Check: acceptance criterion 7
      live on every public page. [4.3, 4.4]
- [x] 4. Docs: `docs/techradar.md` (add or move an entry, the rings,
      how it is built and served, Why it is like this), the `techradar/`
      row in `.kiro/steering/structure.md`, the README services table
      and docs index, `docs/networking.md` (the name). Check: a newcomer
      can add an entry from the doc alone; links resolve.
      #1690.

- [x] 5. Hover details (**live**, amendment 2026-11-25): every blip a
      link to its legend item with the full `<title>`, the CSS hover
      and focus label, the `:target` highlight, the tests of acceptance
      criterion 9, the rendered page. Check: criterion 9 and criterion
      1 live, the probe up. [2.4, 2.8]
      #1705.
The last task ticked sets `status: done`, `closed:`, and closes #1671.
