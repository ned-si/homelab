package web

import (
	"html/template"
	"strconv"
	"strings"
	"time"

	"github.com/ned-si/homelab/dashboard/internal/snapshot"
)

// The chart builders take numbers and dates only and emit svg, g, rect, line
// and title, with numeric attributes and a class from the status set, so the
// result is safe as template.HTML. TestChartMarkup checks every builder.

const (
	meterWidth, meterHeight = 100, 6
	barsWidth, barsHeight   = 300, 60
	barStep, barWidth       = 10, 8
	barsFloor               = 95.0
	barMin, barNone         = 2.0, 3.0
)

func coord(v float64) string {
	return strconv.FormatFloat(v, 'f', 1, 64)
}

func percent(v float64) string {
	return strconv.FormatFloat(v, 'f', 1, 64) + "%"
}

func openSVG(b *strings.Builder, w, h int, label string) {
	b.WriteString(`<svg viewBox="0 0 ` + strconv.Itoa(w) + " " + strconv.Itoa(h) +
		`" preserveAspectRatio="none" role="img" focusable="false" aria-label="` + label + `">`)
}

func rect(b *strings.Builder, class string, x, y, w, h float64) {
	b.WriteString("<rect")
	if class != "" {
		b.WriteString(` class="` + class + `"`)
	}
	b.WriteString(` x="` + coord(x) + `" y="` + coord(y) + `" width="` + coord(w) + `" height="` + coord(h) + `"`)
}

// budgetMeter draws the error budget left (0-100%) as a filled track; at or
// below 0 the track is empty.
func budgetMeter(left int) template.HTML {
	var b strings.Builder
	label := "Error budget exhausted"
	if left > 0 {
		label = "Error budget left: " + strconv.Itoa(left) + "%"
	}
	openSVG(&b, meterWidth, meterHeight, label)
	rect(&b, "track", 0, 0, meterWidth, meterHeight)
	b.WriteString("/>")
	if left > 0 {
		rect(&b, string(monthStatus(left)), 0, 0, float64(min(left, 100)), meterHeight)
		b.WriteString("/>")
	}
	b.WriteString("</svg>")
	return template.HTML(b.String()) //nolint:gosec // G203: numbers only, see TestChartMarkup.
}

// shareBar draws a share (0-100%) as a filled track.
func shareBar(label string, share int) template.HTML {
	var b strings.Builder
	openSVG(&b, meterWidth, meterHeight, label+": "+strconv.Itoa(share)+"%")
	rect(&b, "track", 0, 0, meterWidth, meterHeight)
	b.WriteString("/>")
	if share > 0 {
		rect(&b, "", 0, 0, float64(min(share, 100)), meterHeight)
		b.WriteString("/>")
	}
	b.WriteString("</svg>")
	return template.HTML(b.String()) //nolint:gosec // G203: numbers only, see TestChartMarkup.
}

// barHeight maps a day's availability onto the 95-100% scale.
func barHeight(v float64) float64 {
	h := (min(max(v, barsFloor), 100) - barsFloor) / (100 - barsFloor) * barsHeight
	return max(h, barMin)
}

// dailyBars draws one bar per day, oldest left, the last on covers; each bar
// is coloured by that day's status and titled with its date and value. A
// dashed line marks the target.
func dailyBars(covers time.Time, values []*float64) template.HTML {
	counts := map[status]int{}
	var bars strings.Builder
	for i, v := range values {
		st := dayStatus(v)
		counts[st]++
		day := snapshot.AddDays(covers, -(len(values) - 1 - i)).Format(snapshot.DateLayout)
		h, text := barNone, "No data"
		if v != nil {
			h, text = barHeight(*v), percent(*v)
		}
		rect(&bars, string(st), float64(i*barStep+(barStep-barWidth)/2), barsHeight-h, barWidth, h)
		bars.WriteString("><title>" + day + ": " + text + "</title></rect>")
	}
	parts := []string{strconv.Itoa(counts[statusOK]) + " met"}
	for _, p := range []struct {
		s    status
		word string
	}{{statusWarn, "at risk"}, {statusBad, "missed"}, {statusNone, "without data"}} {
		if counts[p.s] > 0 {
			parts = append(parts, strconv.Itoa(counts[p.s])+" "+p.word)
		}
	}
	var b strings.Builder
	openSVG(&b, barsWidth, barsHeight, strconv.Itoa(len(values))+" days: "+strings.Join(parts, ", "))
	b.WriteString("<g>" + bars.String() + "</g>")
	y := coord(barsHeight - barHeight(target))
	b.WriteString(`<line class="target" x1="0" y1="` + y + `" x2="` + strconv.Itoa(barsWidth) + `" y2="` + y + `"/>`)
	b.WriteString("</svg>")
	return template.HTML(b.String()) //nolint:gosec // G203: numbers and dates only, see TestChartMarkup.
}
