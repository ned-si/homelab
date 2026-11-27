# Tasks: drum-charts-song-cards

One PR per task, in order, in this repository. PR bodies carry
`Spec: drum-charts-song-cards#<n>` and `Refs #1878`. Task 1 starts once
drum-charts-site has closed (its Charts nav and French pages change the
same templates and goldens). drum-charts-per-song-releases task 2 builds
on top of task 1. Merges through `scripts/pr-merge.sh`.

- [x] 1. The card grid (not live: the image deploys in task 2): `home.html`, `charts.css`,
      `render.go`, the catalogue (`home.card_alt` in English and in the
      operator's French, the `home.col_*` keys removed), the tests and
      the golden tree; `docs/drum-charts.md` where it describes the home
      page. Branch `feat/charts-song-cards`. Check: acceptance criteria
      1 and 2; screenshots of the golden home page at 1920x1080,
      390x844 and 320x568 in both themes, locally. [1, 2] #1891, English
      only: main had no French charts pages yet, so the French alt text
      and the grid at `/fr/` come with drum-charts-site task 7, which
      renders the French tree from the same template.
- [x] 2. Deploy (**live** and visible): the `homelab-site` digest pull
      request built from task 1's merge (Renovate's, or by hand on
      `chore/charts-song-cards-deploy`). Check: acceptance criteria 3
      and 4. [1, 2] #1892.

The last task ticked sets `status: done`, `closed:`, moves the index row
to done and closes #1878.
