// Command gridcheck fails when the cards in a screenshot of the page leave
// the column grid of dashboard.css, for the screenshot check of
// scripts/ci/dashboard-screenshots.sh:
//
//	gridcheck [--wide <n>] <dashboard.css> <png> [<png>]
//
// A card is a run of pixels between page-background pixels that holds at
// least minRun pixels of the --panel colour. On every pixel row the cards
// must either be one card across the whole card area, or sit on the column
// tracks from its left edge: one track wide, one gap apart. The track is the
// most common width of the narrower cards. When the screenshot has tracks,
// the cards across the whole area must form exactly <n> blocks, the panels
// that span a row: one more is a card alone on its row, stretched.
package main

import (
	"encoding/hex"
	"errors"
	"flag"
	"fmt"
	"image"
	colour "image/color" //nolint:misspell // The standard library's package path.
	"image/png"
	"io"
	"os"
	"regexp"
)

// corner is how far, in pixels, a card's rounded corner and border, or the
// rounding of fractional tracks, may move a card's edge.
const corner = 8

// minRun is the shortest run of panel pixels that counts as a card: a
// card's padding is 16 px wide, while anti-aliased text on the page
// background matches the panel colour for a pixel or two at most.
const minRun = 12

// channelSlack is how far a pixel's channel may be off a colour and still
// count as that colour.
const channelSlack = 2

func main() {
	if err := run(os.Args[1:], os.Stdout); err != nil {
		_, _ = fmt.Fprintln(os.Stderr, "gridcheck:", err)
		os.Exit(1)
	}
}

func run(args []string, stdout io.Writer) error {
	fs := flag.NewFlagSet("gridcheck", flag.ContinueOnError)
	wide := fs.Int("wide", -1, "panels that span a whole row; -1 skips the count")
	if err := fs.Parse(args); err != nil {
		return err
	}
	args = fs.Args()
	if len(args) < 2 {
		return errors.New("usage: gridcheck [--wide <n>] <dashboard.css> <png> [<png>]")
	}
	css, err := os.ReadFile(args[0])
	if err != nil {
		return err
	}
	panel, err := cssColour(css, "panel")
	if err != nil {
		return fmt.Errorf("%s: %w", args[0], err)
	}
	bg, err := cssColour(css, "bg")
	if err != nil {
		return fmt.Errorf("%s: %w", args[0], err)
	}
	var errs []error
	for _, path := range args[1:] {
		if err := checkFile(path, panel, bg, *wide); err != nil {
			errs = append(errs, fmt.Errorf("%s: %w", path, err))
			continue
		}
		_, _ = fmt.Fprintf(stdout, "%s: cards on the grid\n", path)
	}
	return errors.Join(errs...)
}

// cssColour reads the custom property --<name> from the stylesheet.
func cssColour(css []byte, name string) (colour.RGBA, error) {
	m := regexp.MustCompile(`--` + name + `:\s*#([0-9a-f]{6});`).FindSubmatch(css)
	if m == nil {
		return colour.RGBA{}, fmt.Errorf("no --%s colour", name)
	}
	v, err := hex.DecodeString(string(m[1]))
	if err != nil {
		return colour.RGBA{}, err
	}
	return colour.RGBA{R: v[0], G: v[1], B: v[2], A: 0xff}, nil
}

func checkFile(path string, panel, bg colour.RGBA, wide int) error {
	f, err := os.Open(path) //nolint:gosec // G304: a path the CI script passes.
	if err != nil {
		return err
	}
	defer func() { _ = f.Close() }()
	img, err := png.Decode(f)
	if err != nil {
		return err
	}
	return errors.Join(check(img, panel, bg, wide)...)
}

// span is one card on a pixel row, from x0 to x1 inclusive.
type span struct{ x0, x1 int }

func (c span) width() int { return c.x1 - c.x0 + 1 }

// cardsOn returns the cards crossing pixel row y.
func cardsOn(img image.Image, y int, panel, bg colour.RGBA) []span {
	b := img.Bounds()
	var cards []span
	start, run, longest := -1, 0, 0
	for x := b.Min.X; x <= b.Max.X; x++ {
		if x == b.Max.X || near(img, x, y, bg) {
			if start >= 0 && longest >= minRun {
				cards = append(cards, span{start, x - 1})
			}
			start, run, longest = -1, 0, 0
			continue
		}
		if start < 0 {
			start = x
		}
		if near(img, x, y, panel) {
			run++
		} else {
			run = 0
		}
		longest = max(longest, run)
	}
	return cards
}

// check returns one error per run of pixel rows whose cards leave the
// grid, one when the whole-area blocks are not wide, and one when the image
// has no card at all.
func check(img image.Image, panel, bg colour.RGBA, wide int) []error {
	b := img.Bounds()
	rows := make(map[int][]span)
	left, right := b.Max.X, b.Min.X-1
	for y := b.Min.Y; y < b.Max.Y; y++ {
		cards := cardsOn(img, y, panel, bg)
		if len(cards) == 0 {
			continue
		}
		rows[y] = cards
		left, right = min(left, cards[0].x0), max(right, cards[len(cards)-1].x1)
	}
	if len(rows) == 0 {
		return []error{errors.New("no card in the screenshot")}
	}
	full := func(c span) bool { return c.x0 <= left+corner && c.x1 >= right-corner }
	widths, gaps := make(map[int]int), make(map[int]int)
	for _, cards := range rows {
		for i, c := range cards {
			if !full(c) {
				widths[c.width()]++
			}
			if i > 0 {
				gaps[c.x0-cards[i-1].x1-1]++
			}
		}
	}
	track, gap := mode(widths), mode(gaps)
	onTracks := func(cards []span) bool {
		for i, c := range cards {
			if abs(c.x0-(left+i*(track+gap))) > corner || abs(c.width()-track) > corner {
				return false
			}
		}
		return track > 0
	}

	var errs []error
	start, blocks, inBlock := -1, 0, false
	var at []span
	flush := func(end int) {
		if start >= 0 {
			errs = append(errs, fmt.Errorf("pixel rows %d-%d: cards %v are off the grid (card area x %d-%d, track %d px, gap %d px)",
				start, end, at, left, right, track, gap))
			start = -1
		}
	}
	for y := b.Min.Y; y < b.Max.Y; y++ {
		cards, ok := rows[y]
		isWide := ok && len(cards) == 1 && full(cards[0])
		if isWide && !inBlock {
			blocks++
		}
		inBlock = isWide
		if !ok || isWide || onTracks(cards) {
			flush(y - 1)
			continue
		}
		if start < 0 {
			start, at = y, cards
		}
	}
	flush(b.Max.Y - 1)
	if track > 0 && wide >= 0 && blocks != wide {
		errs = append(errs, fmt.Errorf("%d blocks of cards span the whole card area, want %d: a card alone on its row is stretched", blocks, wide))
	}
	return errs
}

// mode returns the most common key of counts, the smallest on a tie, and 0
// when counts is empty.
func mode(counts map[int]int) int {
	best, n := 0, 0
	for k, c := range counts {
		if c > n || (c == n && k < best) {
			best, n = k, c
		}
	}
	return best
}

func abs(v int) int { return max(v, -v) }

func near(img image.Image, x, y int, want colour.RGBA) bool {
	r, g, b, _ := img.At(x, y).RGBA()
	ch := func(v uint32, w uint8) bool {
		d := int(v>>8) - int(w)
		return d >= -channelSlack && d <= channelSlack
	}
	return ch(r, want.R) && ch(g, want.G) && ch(b, want.B)
}
