package snapshot

import (
	"math"
	"slices"
)

// The helpers round like apps/website/publisher/publisher.py, so the
// side-by-side comparison finds no false differences: Python's round()
// rounds half to even.

// PercentDown returns ratio as a percentage with one decimal, rounded down
// and clamped to 0-100, so an error never shows as 100.0.
func PercentDown(ratio float64) float64 {
	return min(100, max(0, math.Floor(ratio*1000+1e-9)/10))
}

// Budget returns the error budget left as an integer percentage, rounded
// half to even and clamped to -100..100; -100 means exhausted.
func Budget(ratio float64) int {
	return int(min(100, max(-100, math.RoundToEven(ratio*100))))
}

// Share returns part as an integer percentage of total, rounded half to
// even, and 0 when total is 0.
func Share(part, total int) int {
	if total == 0 {
		return 0
	}
	return int(math.RoundToEven(100 * float64(part) / float64(total)))
}

// Median returns the median of xs, the mean of the two middle values for an
// even count, and 0 for none.
func Median(xs []float64) float64 {
	if len(xs) == 0 {
		return 0
	}
	s := slices.Clone(xs)
	slices.Sort(s)
	n := len(s)
	if n%2 == 1 {
		return s[n/2]
	}
	return (s[n/2-1] + s[n/2]) / 2
}

// RoundSeconds returns seconds rounded half to even, at least 1.
func RoundSeconds(seconds float64) int {
	return max(1, int(math.RoundToEven(seconds)))
}
