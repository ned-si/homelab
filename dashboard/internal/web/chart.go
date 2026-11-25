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
	sparkWidth, sparkHeight = 280, 40
	sparkStep, sparkBar     = 10, 8
	sparkMin                = 2.0
	barsWidth, barsHeight   = 300, 60
	barStep, barWidth       = 10, 8
	barsFloor               = 95.0
	barMin, barNone         = 2.0, 3.0
)

func coord(v float64) string {
	return strconv.FormatFloat(v, 'f', 1, 64)
}

// percent is pct with the sign, for text, titles and aria-labels.
func percent(v float64) string {
	return pct(v) + "%"
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
func budgetMeter(left float64) template.HTML {
	var b strings.Builder
	label := "Error budget exhausted"
	if left > 0 {
		label = "Error budget left: " + percent(left)
	}
	openSVG(&b, meterWidth, meterHeight, label)
	rect(&b, "track", 0, 0, meterWidth, meterHeight)
	b.WriteString("/>")
	if left > 0 {
		rect(&b, string(monthStatus(left)), 0, 0, min(left, 100), meterHeight)
		b.WriteString("/>")
	}
	b.WriteString("</svg>")
	return template.HTML(b.String()) //nolint:gosec // G203: numbers only, see TestChartMarkup.
}

// meter draws a utilisation (0-100%) as a track filled in its status
// colour.
func meter(label string, v float64, st status) template.HTML {
	var b strings.Builder
	openSVG(&b, meterWidth, meterHeight, label+": "+percent(v))
	rect(&b, "track", 0, 0, meterWidth, meterHeight)
	b.WriteString("/>")
	if v > 0 {
		rect(&b, string(st), 0, 0, min(v, 100), meterHeight)
		b.WriteString("/>")
	}
	b.WriteString("</svg>")
	return template.HTML(b.String()) //nolint:gosec // G203: numbers only, see TestChartMarkup.
}

// shareBar draws a share (0-100%) as a filled track.
func shareBar(label string, share float64) template.HTML {
	var b strings.Builder
	openSVG(&b, meterWidth, meterHeight, label+": "+percent(share))
	rect(&b, "track", 0, 0, meterWidth, meterHeight)
	b.WriteString("/>")
	if share > 0 {
		rect(&b, "", 0, 0, min(share, 100), meterHeight)
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

// dailyBars draws one bar per day of days (snapshot dates, oldest first),
// the last one today so far and outlined; each bar is coloured by that day's
// status and titled with its date and value. A dashed line marks the target.
func dailyBars(days []string, values []*float64) template.HTML {
	counts := map[status]int{}
	var bars strings.Builder
	for i, v := range values {
		st := dayStatus(v)
		counts[st]++
		class, day := string(st), ""
		if i < len(days) {
			day = days[i]
		}
		if i == len(values)-1 {
			class += " today"
			day += " (today so far)"
		}
		h, text := barNone, noData
		if v != nil {
			h, text = barHeight(*v), percent(*v)
		}
		rect(&bars, class, float64(i*barStep+(barStep-barWidth)/2), barsHeight-h, barWidth, h)
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

// sparkBars draws a signal's buckets, oldest left, the last ending at end,
// on a linear scale from 0 to the largest; all at the minimum height when
// every one is 0. Each bar is titled with its span in Zurich time and its
// count.
func sparkBars(end time.Time, buckets []*int) template.HTML {
	top := 0
	for _, v := range buckets {
		if v != nil {
			top = max(top, *v)
		}
	}
	var bars strings.Builder
	for i, v := range buckets {
		to := end.Add(-time.Duration(len(buckets)-1-i) * snapshot.BucketWidth)
		span := shortTime(to.Add(-snapshot.BucketWidth)) + " to " + shortTime(to)
		class, h, text := "none", sparkMin, noData
		if v != nil {
			class, text = "spark", thousands(*v)
			if top > 0 {
				h = max(sparkMin, float64(*v)/float64(top)*sparkHeight)
			}
		}
		rect(&bars, class, float64(i*sparkStep+(sparkStep-sparkBar)/2), sparkHeight-h, sparkBar, h)
		bars.WriteString("><title>" + span + ": " + text + "</title></rect>")
	}
	var b strings.Builder
	openSVG(&b, sparkWidth, sparkHeight, strconv.Itoa(len(buckets))+" counts of six hours, highest "+thousands(top))
	b.WriteString("<g>" + bars.String() + "</g></svg>")
	return template.HTML(b.String()) //nolint:gosec // G203: numbers and times only, see TestChartMarkup.
}
