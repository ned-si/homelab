package radar

import (
	"fmt"
	"html"
	"math"
	"strconv"
	"strings"
)

// SVG draws the chart: the rings, the axes, the ring names along the
// horizontal axis and one numbered blip per entry, a link to its legend
// item. Styled by class only (techradar.css), so the page's CSP needs no
// inline style; the hover label is CSS, the tooltip the native <title>.
func SVG(blips []Blip) string {
	var b strings.Builder
	fmt.Fprintf(&b, `<svg viewBox="0 0 %d %d" role="group" focusable="false" aria-label="%s">`+"\n",
		Size, Size, html.EscapeString(fmt.Sprintf("Tech radar: %d entries in four quadrants and four rings, listed in the legend below.", len(blips))))
	for _, r := range Radii {
		fmt.Fprintf(&b, `<circle class="ring-line" cx="%d" cy="%d" r="%s"/>`+"\n", centre, centre, num(r))
	}
	fmt.Fprintf(&b, `<line class="axis" x1="0" y1="%d" x2="%d" y2="%d"/>`+"\n", centre, Size, centre)
	fmt.Fprintf(&b, `<line class="axis" x1="%d" y1="0" x2="%d" y2="%d"/>`+"\n", centre, centre, Size)
	for i, r := range Rings {
		mid := (innerRadius(i) + Radii[i]) / 2
		for _, x := range []float64{centre - mid, centre + mid} {
			fmt.Fprintf(&b, `<text class="ring-name" x="%s" y="%d">%s</text>`+"\n", num(x), centre+6, r.Name)
		}
	}
	for _, bl := range blips {
		// The label sits on the side facing the centre, so it stays inside
		// the chart.
		side, dx := "blip-label-start", 14.0
		if bl.X > centre {
			side, dx = "blip-label-end", -14
		}
		fmt.Fprintf(&b, `<a class="blip ring-%s" href="#entry-%s"><title>%s</title>%s<text class="blip-number" x="%s" y="%s" aria-hidden="true">%d</text>`+
			`<g class="blip-label" aria-hidden="true"><text class="%s" x="%s" y="%s">%s</text></g></a>`+"\n",
			bl.Entry.Ring, Slug(bl.Entry.Name), html.EscapeString(label(bl.Number, bl.Entry)), shape(bl), num(bl.X), num(bl.Y+3), bl.Number,
			side, num(bl.X+dx), num(bl.Y+5), html.EscapeString(bl.Entry.Name+" · "+name(Rings, bl.Entry.Ring)))
	}
	b.WriteString("</svg>")
	return b.String()
}

// shape is a circle for an unchanged entry, a triangle pointing to the
// centre (up) or away from it (down) for a moved one, a star for a new one.
func shape(bl Blip) string {
	switch bl.Entry.Moved {
	case "up", "down":
		// The unit vector from the blip to the centre of the chart.
		ux, uy := centre-bl.X, centre-bl.Y
		d := math.Hypot(ux, uy)
		ux, uy = ux/d, uy/d
		if bl.Entry.Moved == "down" {
			ux, uy = -ux, -uy
		}
		px, py := -uy, ux
		return polygon(
			bl.X+10*ux, bl.Y+10*uy,
			bl.X-6*ux+9*px, bl.Y-6*uy+9*py,
			bl.X-6*ux-9*px, bl.Y-6*uy-9*py,
		)
	case "new":
		var pts []float64
		for i := range 10 {
			rad := 10.0
			if i%2 == 1 {
				rad = 4.5
			}
			a := -math.Pi/2 + float64(i)*math.Pi/5
			pts = append(pts, bl.X+rad*math.Cos(a), bl.Y+rad*math.Sin(a))
		}
		return polygon(pts...)
	default:
		return fmt.Sprintf(`<circle cx="%s" cy="%s" r="%d"/>`, num(bl.X), num(bl.Y), BlipRadius)
	}
}

// polygon is a closed path through the points x0, y0, x1, y1, ...
func polygon(xy ...float64) string {
	var b strings.Builder
	b.WriteString(`<path d="M`)
	for i := 0; i+1 < len(xy); i += 2 {
		if i > 0 {
			b.WriteString(" L")
		}
		b.WriteString(num(xy[i]) + " " + num(xy[i+1]))
	}
	b.WriteString(` Z"/>`)
	return b.String()
}

// num prints a coordinate with at most one decimal.
func num(v float64) string {
	return strconv.FormatFloat(round(v), 'f', -1, 64)
}
