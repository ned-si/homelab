package radar

import (
	"fmt"
	"hash/fnv"
	"math"
	"math/rand/v2"
)

// The chart's geometry, in viewBox units.
const (
	Size       = 800
	centre     = Size / 2
	BlipRadius = 8
	// MinDistance between two blip centres: 2 units between their edges.
	MinDistance = 18
	// Margin from a blip centre to a ring line or the vertical axis.
	Margin = 10
	// AxisMargin from a blip centre to the horizontal axis, wider than
	// Margin: the ring names sit on that axis.
	AxisMargin = 16
	attempts   = 500
)

// Radii are the outer radii of the rings, Adopt to Hold.
var Radii = [4]float64{170, 255, 330, 400}

// quadrantStart is the start angle of each quadrant, counter-clockwise from
// the positive x axis with y up: techniques top left, tools top right,
// platform bottom left, infrastructure bottom right.
var quadrantStart = [4]float64{math.Pi / 2, 0, math.Pi, 3 * math.Pi / 2}

// Blip is an entry placed on the chart, numbered as the legend.
type Blip struct {
	Number int
	Entry  Entry
	X, Y   float64
}

// Place numbers the entries in their order and gives each a point inside its
// quadrant and ring. The same entries always get the same points.
func Place(entries []Entry) ([]Blip, error) {
	blips := make([]Blip, 0, len(entries))
	for i, e := range entries {
		q, r := index(Quadrants, e.Quadrant), index(Rings, e.Ring)
		if q < 0 || r < 0 {
			return nil, fmt.Errorf("%q: unknown quadrant or ring", e.Name)
		}
		x, y, ok := find(e, q, r, blips)
		if !ok {
			return nil, fmt.Errorf("%s/%s: no room for %q after %d candidates; widen the ring or move an entry", e.Quadrant, e.Ring, e.Name, attempts)
		}
		blips = append(blips, Blip{Number: i + 1, Entry: e, X: x, Y: y})
	}
	return blips, nil
}

func find(e Entry, q, r int, placed []Blip) (x, y float64, ok bool) {
	h := fnv.New64a()
	_, _ = h.Write([]byte(e.Quadrant + "/" + e.Ring + "/" + e.Name)) // a hash.Hash never fails
	seed := h.Sum64()
	rng := rand.New(rand.NewPCG(seed, seed^0x9e3779b97f4a7c15)) //nolint:gosec // G404: layout, seeded on purpose for the same bytes every run
	inner, outer := innerRadius(r), Radii[r]
	for range attempts {
		// Uniform in the segment's area: the radius from the square root.
		rad := math.Sqrt(rng.Float64()*(outer*outer-inner*inner) + inner*inner)
		angle := quadrantStart[q] + rng.Float64()*math.Pi/2
		x = centre + rad*math.Cos(angle)
		y = centre - rad*math.Sin(angle)
		x, y = round(x), round(y)
		if Inside(x, y, q, r) && free(x, y, placed) {
			return x, y, true
		}
	}
	return 0, 0, false
}

// Inside reports whether a blip centre at (x, y) lies in quadrant q and ring
// r with the margins.
func Inside(x, y float64, q, r int) bool {
	dx, dy := x-centre, centre-y
	rad := math.Hypot(dx, dy)
	inner := innerRadius(r)
	if (inner > 0 && rad < inner+Margin) || rad > Radii[r]-Margin {
		return false
	}
	if math.Abs(dx) < Margin || math.Abs(dy) < AxisMargin {
		return false
	}
	left, top := dx < 0, dy > 0
	switch q {
	case 0:
		return left && top
	case 1:
		return !left && top
	case 2:
		return left && !top
	default:
		return !left && !top
	}
}

func free(x, y float64, placed []Blip) bool {
	for _, b := range placed {
		if math.Hypot(x-b.X, y-b.Y) < MinDistance {
			return false
		}
	}
	return true
}

func innerRadius(r int) float64 {
	if r == 0 {
		return 0
	}
	return Radii[r-1]
}

// round keeps one decimal, the precision the SVG prints.
func round(v float64) float64 {
	return math.Round(v*10) / 10
}
