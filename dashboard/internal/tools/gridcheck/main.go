// Command gridcheck fails when a row of cards in a screenshot of the page
// has a hole, for the screenshot check of scripts/ci/dashboard-screenshots.sh:
//
//	gridcheck <dashboard.css> <png> [<png>]
//
// Cards are runs of pixels in the --panel colour of dashboard.css. Every
// pixel row that crosses a card must have cards from the left edge of the
// card area to its right edge, both taken over the whole screenshot; a row
// that stops short by more than a rounded corner is a hole.
package main

import (
	"encoding/hex"
	"errors"
	"fmt"
	"image"
	colour "image/color" //nolint:misspell // The standard library's package path.
	"image/png"
	"io"
	"os"
	"regexp"
)

// corner is how far, in pixels, a card's rounded corner and border may pull
// a row's first or last panel pixel in from the card area's edge.
const corner = 8

// minRun is the shortest run of panel pixels that counts as a card: a
// card's padding is 16 px wide, while anti-aliased text on the page
// background matches the panel colour for a pixel or two at most.
const minRun = 12

// channelSlack is how far a pixel's channel may be off the panel colour
// and still count as a card.
const channelSlack = 2

var panelVar = regexp.MustCompile(`--panel:\s*#([0-9a-f]{6});`)

func main() {
	if err := run(os.Args[1:], os.Stdout); err != nil {
		_, _ = fmt.Fprintln(os.Stderr, "gridcheck:", err)
		os.Exit(1)
	}
}

func run(args []string, stdout io.Writer) error {
	if len(args) < 2 {
		return errors.New("usage: gridcheck <dashboard.css> <png> [<png>]")
	}
	css, err := os.ReadFile(args[0]) //nolint:gosec // G703: a path the CI script passes.
	if err != nil {
		return err
	}
	panel, err := panelColour(css)
	if err != nil {
		return fmt.Errorf("%s: %w", args[0], err)
	}
	var errs []error
	for _, path := range args[1:] {
		if err := checkFile(path, panel); err != nil {
			errs = append(errs, fmt.Errorf("%s: %w", path, err))
			continue
		}
		_, _ = fmt.Fprintf(stdout, "%s: no hole\n", path)
	}
	return errors.Join(errs...)
}

// panelColour reads --panel from the stylesheet.
func panelColour(css []byte) (colour.RGBA, error) {
	m := panelVar.FindSubmatch(css)
	if m == nil {
		return colour.RGBA{}, errors.New("no --panel colour")
	}
	v, err := hex.DecodeString(string(m[1]))
	if err != nil {
		return colour.RGBA{}, err
	}
	return colour.RGBA{R: v[0], G: v[1], B: v[2], A: 0xff}, nil
}

func checkFile(path string, panel colour.RGBA) error {
	f, err := os.Open(path) //nolint:gosec // G304: a path the CI script passes.
	if err != nil {
		return err
	}
	defer func() { _ = f.Close() }()
	img, err := png.Decode(f)
	if err != nil {
		return err
	}
	return errors.Join(holes(img, panel)...)
}

// span is the panel pixels of one pixel row, from x0 to x1 inclusive.
type span struct{ x0, x1 int }

// holes returns one error per run of pixel rows whose cards do not fill the
// card area, and an error when the image has no card at all.
func holes(img image.Image, panel colour.RGBA) []error {
	b := img.Bounds()
	rows := make(map[int]span)
	left, right := b.Max.X, b.Min.X-1
	for y := b.Min.Y; y < b.Max.Y; y++ {
		s := span{-1, -1}
		run := 0
		for x := b.Min.X; x <= b.Max.X; x++ {
			if x < b.Max.X && isPanel(img, x, y, panel) {
				run++
				continue
			}
			if run >= minRun {
				if s.x0 < 0 {
					s.x0 = x - run
				}
				s.x1 = x - 1
			}
			run = 0
		}
		if s.x0 < 0 {
			continue
		}
		rows[y] = s
		left, right = min(left, s.x0), max(right, s.x1)
	}
	if len(rows) == 0 {
		return []error{errors.New("no card in the screenshot")}
	}
	var errs []error
	start := -1
	var at span
	flush := func(end int) {
		if start >= 0 {
			errs = append(errs, fmt.Errorf("pixel rows %d-%d: cards span x %d-%d, the card area is %d-%d",
				start, end, at.x0, at.x1, left, right))
			start = -1
		}
	}
	for y := b.Min.Y; y < b.Max.Y; y++ {
		s, ok := rows[y]
		if !ok || (s.x0 <= left+corner && s.x1 >= right-corner) {
			flush(y - 1)
			continue
		}
		if start < 0 {
			start, at = y, s
		}
	}
	flush(b.Max.Y - 1)
	return errs
}

func isPanel(img image.Image, x, y int, panel colour.RGBA) bool {
	r, g, b, _ := img.At(x, y).RGBA()
	near := func(v uint32, want uint8) bool {
		d := int(v>>8) - int(want)
		return d >= -channelSlack && d <= channelSlack
	}
	return near(r, panel.R) && near(g, panel.G) && near(b, panel.B)
}
