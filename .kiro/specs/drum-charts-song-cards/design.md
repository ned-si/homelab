# Design: drum-charts-song-cards

## Overview

One change to the generator in `drumcharts/`: the home page template
renders a list of cards instead of the song table, `charts.css` gains
the grid and card rules, the catalogue gains the thumbnail's alt text in
both languages. The thumbnail is the first page image, which the site
already serves. drum-charts, the manifest, the pin, nginx, the Gateway
and the CSP do not change. The change reaches the site like any
generator change: `site-publish` builds `homelab-site`, and its digest
pull request deploys it.

## Thumbnails

| Option | For | Against |
| --- | --- | --- |
| **The first page image, `/pages/<slug>-1.svg`, shown at card size** (chosen) | Already in the data, validated by the allow-list and gzipped; no new tool, file or contract; vector, so sharp on any screen; the same URL as the song page's first sheet, so one download serves both | 27 to 74 KiB gzipped per song, 685 KiB for the 14 of today; the browser draws a full page of notation in a small box |
| A small PNG per song, `pdftocairo -png -scale-to 300` in drum-charts | About a tenth of the bytes | A change of the data contract (file set, schema, a raster check in the generator) in the pipeline that drum-charts-per-song-releases is rewriting; a second image per song to keep in step |
| A raster made here from the SVG or the PDF | No change in drum-charts | Needs a rasteriser outside Go's standard library, an apt tool against the rule that every tool is pinned by version and checksum |
| Album covers | What music apps show | Copyrighted, fetched from outside; rejected by the operator |
| A cropped `<svg>` view of the top of the page | Shows the title area larger | A second SVG per song, rewritten by the generator, outside the allow-list's tested inputs |

`loading="lazy"` keeps a phone to the cards near its screen; at
1920x1080 about two rows (twelve cards) are in view under the intro. If the grid
grows to where the weight matters, the PNG option becomes its own
issue.

## Markup

`assets/home.html`, the part between the intro and the release line
(English shown; the French page links `/fr/<slug>/`):

```html
<h2 id="songs">Songs</h2>
<ul class="cards" aria-labelledby="songs">
<li>
<a class="card" href="/tool-schism/">
<img src="/pages/tool-schism-1.svg" width="595" height="842" loading="lazy" alt="First page of Schism by Tool">
<span class="card-title">Schism</span>
<span class="card-artist">Tool</span>
</a>
<p class="card-meta">2 pages · <a href="/pdf/tool-schism.pdf" download aria-label="Download the PDF of Schism">PDF</a></p>
</li>
</ul>
```

- `width` and `height` come from the first page as validated
  (`int(math.Round(v))` of the viewBox, 595 and 842 for A4), so the
  space is reserved before the image loads.
- A list, so screen readers announce the number of songs; the heading
  names it.
- The card holds no other link or control, so it is one tab stop; the
  PDF link is the next one.

`render.go`: the home page's row gains the song page's path, the first
page (`image` with its alt text) and the page count text
(`m.pages(n)`); `homeView` drops `ColSong`, `ColArtist`, `ColPages` and
`ColPDF`.

## Styles

`assets/charts.css`; the `.songs` rules go, these come in (colours only
through the palette, so `site_markup.py --css` passes):

```css
/* Cards in rows: two on a phone, six in the 72rem container. */
.cards {
  display: grid;
  grid-template-columns: repeat(auto-fill, minmax(8rem, 1fr));
  gap: 1rem;
  margin: 1rem 0 0;
  padding: 0;
  list-style: none;
}
@media (min-width: 40rem) {
  .cards { grid-template-columns: repeat(auto-fill, minmax(10rem, 1fr)); }
}
.cards li { display: flex; flex-direction: column; min-width: 0; }
.card {
  flex: 1;
  display: block;
  padding: 0.5rem;
  color: var(--fg);
  background: var(--panel);
  border: 1px solid var(--rule);
  border-radius: 0.4rem;
  text-decoration: none;
}
.card:hover { border-color: var(--link); }
.card:focus-visible { outline: 2px solid var(--link); outline-offset: 3px; }
/* A4 portrait; the sheet carries its own white background. */
.card img {
  display: block;
  width: 100%;
  height: auto;
  aspect-ratio: 210 / 297;
  object-fit: cover;
  object-position: top;
  border: 1px solid var(--rule);
}
.card-title, .card-artist { display: block; line-height: 1.3; overflow-wrap: anywhere; }
.card-title { margin-top: 0.5rem; font-weight: 600; }
.card-artist, .card-meta { color: var(--muted); font-size: 0.875rem; }
.card-meta { margin: 0.3rem 0 0; }
```

The columns, from `layout.css` (body at most 72rem, padded 1.25rem a
side):

| Viewport | Content width | Columns | Card width |
| --- | --- | --- | --- |
| 320 px | 280 px | 2 | 132 px |
| 390 px | 350 px | 2 | 167 px |
| 1920 px | 1112 px | 6 | 172 px |

A 132 px card leaves 114 px for text. The fixture's longest word,
`Underschool`, takes about 80 px in the artist line and about 105 px as
a bold title at the body size; `overflow-wrap: anywhere` breaks anything
longer instead of widening the grid. The focus outline uses the colour and offset of the nav's
(`layout.css`), so focus looks the same on every link of the site.

## Strings

One new key; four go. The French is a proposal until the operator
corrects it, and task 1 merges only with his text.

| Key | English | French |
| --- | --- | --- |
| `home.card_alt` (new) | First page of {title} by {artist} | Première page de {title} par {artist} (proposed) |
| `home.col_song`, `home.col_artist`, `home.col_pages`, `home.col_pdf` | Removed | Removed |

Reused as they are: `home.songs`, `pages.one`, `pages.other`,
`home.pdf`, `home.pdf_label`.

## Checks

| Check | Change |
| --- | --- |
| Golden tree (`render_test.go`) | The English and French home pages are regenerated; a test asserts one card per song in order, each with its thumbnail, alt text, `loading="lazy"`, `width` and `height`, and no `<table>` |
| `TestCatalogue` | Covers the new key in both languages |
| `site_markup.py` | Unchanged; runs over the render and `charts.css` |
| `scripts/ci/layout-check.sh` | Unchanged; already measures the charts home page (drum-charts-site task 6) |
| `site-serve-check.sh`, PostSync smoke, image smoke | Unchanged; the thumbnails are the page images they already check |
| Live | Acceptance criteria 3 and 4, screenshots with chrome-headless-shell as `layout-check.sh` runs it |

## Error handling

Nothing new: a song always has a first page (the manifest's `pages` is
1 to 3 and the file set is exact), so every card has a thumbnail. A
thumbnail that fails to load shows its alt text in the card, and the
title and artist stay readable under it.
