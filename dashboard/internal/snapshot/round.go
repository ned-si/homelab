package snapshot

import (
	"math"
	"slices"
)

// The percentages are written at full precision: the web role rounds each
// once, when it formats it (design.md, "Rounding").

// ToPercent returns ratio as a percentage clamped to 0-100.
func ToPercent(ratio float64) float64 {
	return min(100, max(0, 100*ratio))
}

// BudgetPercent returns the error budget left as a percentage clamped to
// -100..100; -100 means exhausted.
func BudgetPercent(ratio float64) float64 {
	return min(100, max(-100, 100*ratio))
}

// SharePercent returns part as a percentage of total, and 0 when total is 0.
func SharePercent(part, total int) float64 {
	if total == 0 {
		return 0
	}
	return 100 * float64(part) / float64(total)
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

// Round returns x rounded half to even to decimals places.
func Round(x float64, decimals int) float64 {
	p := math.Pow10(decimals)
	return math.RoundToEven(x*p) / p
}

// RoundSeconds returns seconds rounded half to even, at least 1.
func RoundSeconds(seconds float64) int {
	return max(1, int(math.RoundToEven(seconds)))
}
