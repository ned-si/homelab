# Tasks: drum-charts-site

One PR per task, in order; each names its repository. Task 7 waits for
site-theme-language task 4 and the operator's French corrections, and
tasks 8 and 9 do not wait for task 7. Each task merges after its review
round and is checked live where it changes a public page (operator,
2026-11-24: no approval pauses). In this repository, merges go through
`scripts/pr-merge.sh`; in ned-si/drum-charts, a squash merge on a green
`build`, signed commits. No task writes to the cluster outside Argo CD.
Before each merge, rebase on `main`; when another open pull request
changes the same lines (the shared nav, `site_markup.py`,
`layout-check.sh`), wait for it to merge and rebase. Defaults:
[requirements.md](requirements.md#decided-defaults).

If site-theme-language task 4 has not merged when tasks 1-6, 8 and 9 are
done, task 7 moves to an issue labelled `blocked` (`area/website`,
linked to #1662), its line here moves under a "Deferred" heading with
that issue's number, and the spec closes, as pentest-programme did with
its task 6.

- [x] 1. Rename one slug (**ned-si/drum-charts**): `git mv
      songs/bloodhound-gang-fuck.ly
      songs/bloodhound-gang-foxtrot-uniform-charlie-kilo.ly` and its
      README row ([design, One slug renamed first](design.md#one-slug-renamed-first)).
      Check: `build` green; the next release has
      `bloodhound-gang-foxtrot-uniform-charlie-kilo.pdf` and no
      `bloodhound-gang-fuck.pdf`; the README's Songs table still has one
      row per file in `songs/`. [3.11]
      ned-si/drum-charts#9.
- [x] 2. Site data and its image (**ned-si/drum-charts**):
      `scripts/site-data.py`, `site-data.Dockerfile`, `make site-data`;
      in `build.yaml` the tag output of `charts`, the site-data step and
      its artifact, the release job on that tag with `--clobber` on an
      existing tag and its concurrency group, the `site-data` job with
      its concurrency group and the head-of-`main` check before `:main`
      moves ([design, Workflow](design.md#workflow)); the cosign and
      action pins copied from this repository's `ci.yaml` and
      `site-publish.yaml`; the README (Layout, CI, and in Naming the
      rule that `title` is the artist and `subtitle` the song). With the
      pull request: an issue in ned-si/drum-charts for Renovate there
      (Backlog on the board), not part of this spec. After the merge:
      the operator sets the GHCR package `drum-charts` to public. Check:
      `build` green on the pull request and on `main`; `cosign verify`
      of `:main` with the drum-charts identity; an anonymous `docker
      pull` of it; its `/charts/` holds 15 PDFs, 25 page images and
      `charts.json`, and no `.mp3`; acceptance criteria 13 (on a
      throwaway branch, deleted after) and 15. [1]
      ned-si/drum-charts#10.
- [ ] 3. Generator and CI (**ned-si/homelab**, not live): the
      `drumcharts/` module (validation, allow-list, templates, the
      English catalogue, fixture, the golden tree), `drumcharts/source.yaml`
      with the digest of task 2, `scripts/ci/drumcharts-data.sh`,
      `scripts/ci/drumcharts-check.sh` and the `drumcharts` job in the
      `ci` job's `needs:`; in `site_markup.py` `charts.nedsi.io` in
      `SITE_HOSTS` and `THEMED`, the two `LINKS` and the charts-only
      media rule, with their tests; in `site-check.sh` the `drumcharts/`
      filter and the copies, and `task site:layout-sync`; the Renovate
      rule; the site-theme-language Host glossary line. Check:
      acceptance criteria 4-7; the real render read at 390 and 1920 px
      in both themes, locally. [2.1, 2.2, 2.4, 3, 4.1, 4.4, 4.5, 8]
- [ ] 4. The site image carries the charts (**ned-si/homelab**, not
      served): `site-publish.yaml` (paths, Go with `GOTOOLCHAIN: local`,
      cosign, verify, render), `site/Dockerfile`, `.gitignore`, the
      image smoke test's file check. Then the `homelab-site` digest pull
      request deploys it with no visible change. Check: `site-publish`
      green; the deployed digest's `/usr/share/nginx/charts/` holds
      `index.html` and one directory per song (`docker create` and
      `docker cp` of that digest); the website PostSync smoke passes.
      [2.3]
- [ ] 5. Serving at `charts.nedsi.io` (**ned-si/homelab**, live).
      Operator first: no unowned `charts` record in the `nedsi.io` zone.
      The certificate, the two listeners, the HTTPRoute hostnames, the
      nginx server block and map entry, the probe and SLO rules with
      their tests, the `docs/sre.md` row, the pentest scope, the serve
      check with the golden tree mounted, the PostSync smoke and the
      image smoke cases of [design, Checks](design.md#checks),
      `scripts/charts-check.sh`, `task render`. Check:
      `site-serve-check.sh` green in the `site` job; acceptance
      criteria 1, 2, 3, 8 and 16 live. [3.4, 3.11, 4.2, 4.3, 5]
- [ ] 6. Links (**ned-si/homelab**, live): "Charts" in `NAV` and the
      navigation bars of the blog, the landing page, the dashboard, the
      tech radar and the charts site, with the golden pages, the golden
      tree and screenshots; the landing page's overview item and card
      link; the privacy page's "Sent to" row; the charts pages in
      `layout-check.sh`; the site-theme-language lines this spec
      supersedes. If site-theme-language task 4 has merged, also the
      French nav label, landing text and privacy row, from the reviewed
      table. Then the `homelab-site` and dashboard image deploys.
      Check: acceptance criteria 9-11 live. [3.7, 6.1-6.4]
- [ ] 7. French at `charts.nedsi.io/fr/` (**ned-si/homelab**, live),
      after site-theme-language task 4: the `fr` catalogue from the
      reviewed French of [design, Strings](design.md#strings), the
      `fr/` tree, the toggle, `hreflang` and canonical, `TestCatalogue`,
      the golden pages in French, the French `NAV` target for Charts.
      Check: acceptance criterion 14 live. [7]
- [ ] 8. Docs (**ned-si/homelab**): `docs/drum-charts.md`;
      `docs/website.md` (the host, the copies, the generator); the README
      Services table, the public pages line and the layout table;
      `docs/networking.md` (the name); the `drumcharts/` row in
      `.kiro/steering/structure.md`. Check: a newcomer can tell from the
      docs alone how a new chart reaches the site and how to see that the
      site is current; links resolve. [6.5]
- [ ] 9. Link the site from drum-charts (**ned-si/drum-charts**): keep
      the Songs table and the Next section as they are, and add one line
      under the Songs heading: `Read or download every chart at
      [charts.nedsi.io](https://charts.nedsi.io/).` Its merge is the
      end-to-end test. Check: the Songs table still has one row per file
      in `songs/`; acceptance criterion 12. [2.1, 2.3]

The last task ticked sets `status: done`, `closed:`, and closes #1761.
