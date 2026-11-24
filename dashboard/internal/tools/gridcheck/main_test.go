package main

import (
	"bytes"
	"image"
	colour "image/color" //nolint:misspell // The standard library's package path.
	"image/png"
	"io"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

var (
	bg    = colour.RGBA{0x17, 0x19, 0x1b, 0xff}
	panel = colour.RGBA{0x21, 0x24, 0x27, 0xff}
	rule  = colour.RGBA{0x34, 0x38, 0x3c, 0xff}
)

// page draws rows of cards on tracks 300 px wide with 16 px gaps, from
// x 20; each row lists its cards' widths in tracks (1 to 3), 0 for an
// empty track.
func page(rows ...[]int) *image.RGBA {
	img := image.NewRGBA(image.Rect(0, 0, 1000, 60+len(rows)*120))
	fill(img, img.Bounds(), bg)
	const col, gap = 300, 16
	for i, row := range rows {
		x, y := 20, 20+i*120
		for _, n := range row {
			if n == 0 {
				x += col + gap
				continue
			}
			w := n*col + (n-1)*gap
			card(img, image.Rect(x, y, x+w, y+100))
			x += w + gap
		}
	}
	return img
}

func fill(img *image.RGBA, r image.Rectangle, c colour.RGBA) {
	for y := r.Min.Y; y < r.Max.Y; y++ {
		for x := r.Min.X; x < r.Max.X; x++ {
			img.SetRGBA(x, y, c)
		}
	}
}

// card draws a bordered panel with its corners cut, as a rounded corner
// renders, and a line of text in the middle.
func card(img *image.RGBA, r image.Rectangle) {
	fill(img, r, rule)
	fill(img, r.Inset(1), panel)
	for _, c := range []image.Point{r.Min, {r.Max.X - 4, r.Min.Y}, {r.Min.X, r.Max.Y - 4}, {r.Max.X - 4, r.Max.Y - 4}} {
		fill(img, image.Rectangle{c, c.Add(image.Pt(4, 4))}, bg)
	}
	fill(img, image.Rect(r.Min.X+16, r.Min.Y+40, r.Max.X-16, r.Min.Y+50), colour.RGBA{0xe3, 0xe5, 0xe7, 0xff})
}

// withText adds anti-aliased glyph edges in the panel colour on the page
// background, above the cards.
func withText(img *image.RGBA) *image.RGBA {
	for x := 100; x < 400; x += 7 {
		fill(img, image.Rect(x, 5, x+2, 15), panel)
	}
	return img
}

func TestCheck(t *testing.T) {
	tests := []struct {
		name string
		img  image.Image
		wide int
		errs int
	}{
		{"full rows", page([]int{1, 1, 1}, []int{1, 1, 1}), 0, 0},
		{"last row left-aligned", page([]int{1, 1, 1}, []int{1, 1, 1}, []int{1}), 0, 0},
		{"panels and cards", page([]int{3}, []int{3}, []int{1, 1, 1}, []int{1, 1}), 2, 0},
		{"one column", page([]int{1}, []int{1}, []int{1}), 1, 0},
		{"a lone card stretched", page([]int{3}, []int{1, 1, 1}, []int{3}), 1, 1},
		{"stretch not counted", page([]int{3}, []int{1, 1, 1}, []int{3}), -1, 0},
		{"a card two tracks wide", page([]int{1, 1, 1}, []int{2, 1}), 0, 1},
		{"an empty track between cards", page([]int{1, 1, 1}, []int{1, 0, 1}), 0, 1},
		{"off the grid in two rows", page([]int{1, 1, 1}, []int{0, 1}, []int{1, 1, 1}, []int{2}), 0, 2},
		{"text pixels in the panel colour", withText(page([]int{1, 1, 1})), 0, 0},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			if got := check(tc.img, panel, bg, tc.wide); len(got) != tc.errs {
				t.Errorf("check(wide %d) = %v, want %d errors", tc.wide, got, tc.errs)
			}
		})
	}
}

func TestNoCard(t *testing.T) {
	img := image.NewRGBA(image.Rect(0, 0, 100, 100))
	fill(img, img.Bounds(), bg)
	got := check(img, panel, bg, -1)
	if len(got) != 1 || !strings.Contains(got[0].Error(), "no card") {
		t.Errorf("check() on an empty page = %v, want one no card error", got)
	}
}

func TestRun(t *testing.T) {
	dir := t.TempDir()
	css := filepath.Join(dir, "dashboard.css")
	if err := os.WriteFile(css, []byte(":root {\n  --bg: #17191b;\n  --panel: #212427;\n}\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	write := func(name string, img image.Image) string {
		var b bytes.Buffer
		if err := png.Encode(&b, img); err != nil {
			t.Fatal(err)
		}
		p := filepath.Join(dir, name)
		if err := os.WriteFile(p, b.Bytes(), 0o600); err != nil {
			t.Fatal(err)
		}
		return p
	}
	good := write("good.png", page([]int{3}, []int{1, 1, 1}, []int{1}))
	bad := write("bad.png", page([]int{3}, []int{1, 1, 1}, []int{3}))
	if err := run([]string{"--wide", "1", css, good}, io.Discard); err != nil {
		t.Errorf("run(good) = %v, want nil", err)
	}
	if err := run([]string{"--wide", "1", css, good, bad}, io.Discard); err == nil || !strings.Contains(err.Error(), "bad.png") {
		t.Errorf("run(good, bad) = %v, want an error naming bad.png", err)
	}
	if err := run([]string{good, good}, io.Discard); err == nil {
		t.Error("run() with no --panel in the stylesheet = nil, want an error")
	}
}
