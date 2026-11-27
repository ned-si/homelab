---
kind: change
status: done
created: 2026-11-27
closed: 2026-11-27
issue: 1878
---
# Requirements: drum-charts-song-cards

## Introduction

The home page of `https://charts.nedsi.io/`
([drum-charts-site](../drum-charts-site/requirements.md)) lists the
songs in a table: title, artist, page count, PDF. The operator asked on
2026-11-27 for a grid instead, like the song grid of a music app (his
example: Drumeo's Songs page, dark cards in rows): one card per song in
A4 portrait ratio, a thumbnail of the chart's first page, the title and
the artist under it. He chose first-page thumbnails over album covers,
which are copyrighted and would have to be fetched from outside.

This spec replaces the table with that grid. Everything else on the
charts site stays: the song pages, the legend, the PDFs, the order, the
data from drum-charts, the serving, the checks. The thumbnails are the
first-page images the site already serves
([design, Thumbnails](design.md#thumbnails)), so drum-charts and its
data contract do not change.

[drum-charts-site](../drum-charts-site/) is being finished by another
run, so this spec does not edit it; [Supersedes](#supersedes) lists the
lines of it that no longer hold once task 1 merges.

## Glossary

- **Card**: one song on the home page: a link to the song's page holding
  the thumbnail, the title and the artist.
- **Thumbnail**: the song's first page image, `/pages/<slug>-1.svg`,
  shown at card size.
- **Grid**: the list of cards, in rows.
- **Charts site**, **song**, **slug**, **page image**, **manifest**,
  **generator**, **message catalogue**: as in the
  [drum-charts-site glossary](../drum-charts-site/requirements.md#glossary).

## Requirement 1: The grid

**User story:** As a drummer, I want to pick a song by the look of its
chart and its name, as in a music app.

1. THE home page SHALL show every song of the manifest once as a card,
   in the order of drum-charts-site Requirement 3.1 (artist, then
   title, case-insensitive), in a grid of rows. It SHALL hold no song
   table.
2. EACH card SHALL show the song's thumbnail in A4 portrait ratio
   (210:297), then the title, then the artist, just under the
   thumbnail. Titles and artists come from the manifest, untranslated.
3. EACH card SHALL be one link to the song's page `/<slug>/`, with a
   visible focus outline from the keyboard, and nothing else inside it
   that can be focused.
4. UNDER each card, outside its link, THE page SHALL show the page count
   and a link to the song's PDF with the `download` attribute and the
   label of drum-charts-site (`Download the PDF of <title>`).
5. THE thumbnail SHALL be an `<img>` with `width` and `height` from the
   page image, `loading="lazy"` and the text alternative
   `First page of <title> by <artist>` (in French as the operator
   corrects it, [design, Strings](design.md#strings)).
6. THE sheet SHALL stay white with black notation in both themes, as on
   the song pages; the card around it SHALL use the theme's colours.
7. THE grid SHALL read without horizontal scrolling at 320 px wide and
   at 390x844 (two cards per row) and at 1920x1080 (six per row), with
   no title or artist cut off.

## Requirement 2: Same rules as the rest of the site

1. THE thumbnails SHALL come from the build: the page images already in
   the site data. Nothing is rendered in the browser or the pod, and
   nothing is fetched from another site.
2. THE pages SHALL keep the rules of drum-charts-site Requirement 4.1
   and 3.7: no JavaScript, no inline style, the CSP unchanged, the
   shared `layout.css`, the navigation bar, the preferences and the
   footer. New styles go in `charts.css`, with no colour literal.
3. THE English page `/` and the French page `/fr/` SHALL both show the
   grid.
4. EVERY new user-visible string SHALL be in the catalogue in English and
   French; the French SHALL be published only as the operator corrects
   it (drum-charts-site Requirement 7.3).

## Non-functional requirements

- Weight: the 14 first pages served today weigh 27 to 74 KiB gzipped
  each, 685 KiB together (measured on 2026-11-27); they load lazily, and
  each is the same URL as the first sheet of its song page, so it comes
  from the cache there.
- Cost: nothing paid; no new tool, image or package.

## Acceptance criteria

1. `go test ./...` in `drumcharts/` passes: the golden home pages
   (English and French) hold one card per song in order, each
   `<a class="card" href="/<slug>/">` with one `<img>` of
   `/pages/<slug>-1.svg` with `width`, `height`, `loading="lazy"` and
   the alt text, then the title and the artist, followed by the page
   count and the PDF link with `download`; no `<table>`. The catalogue
   test passes with the new key in both languages. [1.1-1.5, 2.4]
2. In `ci`: `site_markup.py` passes the rendered charts site and
   `charts.css` (`--css`), and `scripts/ci/layout-check.sh` passes with
   the charts home page in its list. [2.2]
3. Live, after the deploy: `https://charts.nedsi.io/` and
   `https://charts.nedsi.io/fr/` each show 14 cards; every thumbnail URL
   answers `200` as `image/svg+xml` with `Content-Encoding: gzip`; the
   `Content-Security-Policy` header equals the one before the change.
   [1.1, 2.1, 2.3]
4. Screenshots of `/` and `/fr/` at 1920x1080, 390x844 and 320x568, in
   the dark and the light theme (12 in all): cards in rows (six at 1920,
   two at 390 and 320), A4 thumbnails on white, title and artist
   readable and whole, no horizontal scrollbar. One more at 1920x1080
   after pressing Tab until a card has the focus shows its outline.
   [1.2, 1.3, 1.6, 1.7]

## Out of scope

- Album covers or any image from outside the charts.
- Search, filters or sorting controls (no JavaScript, and
  drum-charts-site keeps one list).
- A card for the legend: it stays the link in the intro.
- Smaller raster thumbnails made in drum-charts: a data contract change,
  only if the weight becomes a problem ([design](design.md#thumbnails)).
- The song and legend pages.

## Supersedes

These lines of [drum-charts-site](../drum-charts-site/) no longer hold
once task 1 merges:

| drum-charts-site line | Becomes |
| --- | --- |
| Requirement 3.1, "Each row SHALL show the title (a link to the song's page), the artist, the page count and a link to its PDF" | Requirement 1 of this spec: a card per song, the page count and the PDF link under it |
| Design, The pages, the home page's `<table class="songs">` | [design, Markup](design.md#markup) |
| Design, The pages, `charts.css`, the `.songs` rules | [design, Styles](design.md#styles) |
| Design, Strings, `home.col_song`, `home.col_artist`, `home.col_pages`, `home.col_pdf` | Removed; `home.card_alt` added ([design, Strings](design.md#strings)) |

## Decided defaults

| Topic | Default | Reason |
| --- | --- | --- |
| Thumbnail | The first page image the site already serves | No new data, tool or contract; sharp at any pixel density; cached for the song page. The operator's choice of first pages over covers |
| Text place | Under the thumbnail, not over it | Text over a white sheet needs a scrim and hides the notation; under it keeps the contrast of the page colours |
| PDF link | Under the card, outside its link | A link cannot hold another link; the card stays one link, as asked |
| Page count | Kept, next to the PDF link, with the existing strings | It tells a drummer whether the chart needs one stand or two (drum-charts-site, Order and metadata) |
| Alt text | `First page of <title> by <artist>`, as the operator asked | His wording. The link's accessible name then holds the title and artist twice (the alt, then the text); an empty alt would avoid that but drop his wording |
| Columns | Two at 320 and 390 px, six at 1920 | Two keeps a phone's thumbnails large enough to tell charts apart; six fills the 72rem container |
