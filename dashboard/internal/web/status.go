package web

// status is a figure's colour class; its word goes next to it on the page
// (design.md, "Status colours").
type status string

const (
	statusOK   status = "ok"
	statusWarn status = "warn"
	statusBad  status = "bad"
	statusNone status = "none"
)

// target is the availability SLO, in percent.
const target =  99.5

// dayWarnFloor is the lowest daily availability that is still "warn": below
// it one day spent a quarter of the month's error budget, the postmortem
// trigger of docs/sre.md.
const dayWarnFloor = 96.25

// budgetWarnAbove is the error budget left, in percent, above which 30 days
// are "ok".
const budgetWarnAbove = 25

// monthStatus is the 30-day status of an app with a full window.
func monthStatus(budgetLeft int) status {
	switch {
	case budgetLeft > budgetWarnAbove:
		return statusOK
	case budgetLeft >= 0:
		return statusWarn
	default:
		return statusBad
	}
}

// sinceStatus is the 30-day status of an app with fewer than 30 days of
// data, which has no meaningful budget yet.
func sinceStatus(availability float64) status {
	if availability >= target {
		return statusOK
	}
	return statusBad
}

// dayStatus is the status of one day's availability; nil is a day without
// probes.
func dayStatus(v *float64) status {
	switch {
	case v == nil:
		return statusNone
	case *v >= target:
		return statusOK
	case *v >= dayWarnFloor:
		return statusWarn
	default:
		return statusBad
	}
}

// monthWord is the word shown next to a 30-day status.
func monthWord(s status) string {
	switch s {
	case statusOK:
		return "Met"
	case statusWarn:
		return "At risk"
	case statusBad:
		return "Missed"
	default:
		return "No data"
	}
}

func Throwaway() {}
