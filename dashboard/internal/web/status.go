package web

import "time"

// status is a figure's colour class; its word goes next to it on the page
// (design.md, "Status colours").
type status string

const (
	statusOK   status = "ok"
	statusWarn status = "warn"
	statusBad  status = "bad"
	statusNone status = "none"
)

// noData is the word of a figure without data.
const noData = "No data"

// target is the availability SLO, in percent.
const target = 99.5

// dayWarnFloor is the lowest daily availability that is still "warn": below
// it one day spent a quarter of the month's error budget, the postmortem
// trigger of docs/sre.md.
const dayWarnFloor = 96.25

// budgetWarnAbove is the error budget left, in percent, above which 30 days
// are "ok".
const budgetWarnAbove = 25

// monthStatus is the 30-day status of an app with a full window, from the
// raw budget left, never the rounded text.
func monthStatus(budgetLeft float64) status {
	switch {
	case budgetLeft > budgetWarnAbove:
		return statusOK
	case budgetLeft >= 0:
		return statusWarn
	default:
		return statusBad
	}
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
		return noData
	}
}

// appState is the class and word of an app's current state.
func appState(state string) (status, string) {
	switch state {
	case "up":
		return statusOK, "Up"
	case "down":
		return statusBad, "Down"
	default:
		return statusNone, noData
	}
}

// The thresholds of the certificates: cert-manager renews at 30 days left,
// and the two certificate alerts fire at 21 and 7.
const (
	certWarnAt = 21
	certBadAt  = 7
)

// certStatus is the status of a certificate's days left; nil has no probe
// result.
func certStatus(days *int) (status, string) {
	switch {
	case days == nil:
		return statusNone, noData
	case *days > certWarnAt:
		return statusOK, "Valid"
	case *days >= certBadAt:
		return statusWarn, "Renewal late"
	default:
		return statusBad, "Expiring"
	}
}

// limits are the thresholds of a figure that is worse the higher it is: ok
// below Warn, warn from Warn to Bad (both included), bad above Bad.
type limits struct{ Warn, Bad float64 }

// The thresholds of the cluster card (design.md, "Status colours"): from an
// alert where there is one, otherwise the dashboard's defaults.
var (
	useLimits        = limits{80, 95}     // node and NAS CPU and memory
	diskLimits       = limits{85, 92}     // NodeFilesystemNearlyFull, -CriticallyFull
	pressureLimits   = limits{10, 25}     // share of time with a task waiting
	poolLimits       = limits{80, 90}     // NASPoolNearlyFull, NASPoolCriticallyFull
	loadLimits       = limits{1, 2}       // NAS load per core
	errorShareLimits = limits{0.5, 5}     // 5xx share: 0.5% is the SLO's error rate
	p95Limits        = limits{1000, 5000} // milliseconds
	restartLimits    = limits{6, 20}
	volumeLimits     = limits{85, 95} // PersistentVolumeNearlyFull, -CriticallyFull
)

// level is the status of v against l; nil has no data.
func level(v *float64, l limits) status {
	switch {
	case v == nil:
		return statusNone
	case *v < l.Warn:
		return statusOK
	case *v <= l.Bad:
		return statusWarn
	default:
		return statusBad
	}
}

// errorLevel is the status of an error count or rate: any error is bad.
func errorLevel(v *float64) status {
	switch {
	case v == nil:
		return statusNone
	case *v > 0:
		return statusBad
	default:
		return statusOK
	}
}

// levelWord is the word of a threshold status, after the alerts' severities.
func levelWord(s status) string {
	switch s {
	case statusOK:
		return "OK"
	case statusWarn:
		return "Warning"
	case statusBad:
		return "Critical"
	default:
		return noData
	}
}

// argoStatus is ok when every application is Synced and Healthy.
func argoStatus(apps, synced, healthy int) status {
	if synced == apps && healthy == apps {
		return statusOK
	}
	return statusWarn
}

// band is a DORA performance cluster of the 2023 State of DevOps report.
type band string

const (
	bandElite  band = "Elite"
	bandHigh   band = "High"
	bandMedium band = "Medium"
	bandLow    band = "Low"
)

// bandStatus is the colour of a band: elite and high are ok.
func bandStatus(b band) status {
	switch b {
	case bandElite, bandHigh:
		return statusOK
	case bandMedium:
		return statusWarn
	default:
		return statusBad
	}
}

// bandRank orders the bands from best to worst.
var bandRank = map[band]int{bandElite: 0, bandHigh: 1, bandMedium: 2, bandLow: 3}

// overallBand is the lowest of bs, so one weak metric is never averaged
// away; it is "" when bs is empty or holds a metric without data ("").
func overallBand(bs []band) band {
	if len(bs) == 0 {
		return ""
	}
	out := bandElite
	for _, b := range bs {
		r, ok := bandRank[b]
		if !ok {
			return ""
		}
		if r > bandRank[out] {
			out = b
		}
	}
	return out
}

const (
	day   = 24 * time.Hour
	week  = 7 * day
	month = 30 * day
)

// deployBand bands the deploys of 30 days: daily or on demand, weekly to
// daily, monthly to weekly, less.
func deployBand(deploys int) band {
	switch {
	case deploys >= 30:
		return bandElite
	case deploys >= 4:
		return bandHigh
	case deploys >= 1:
		return bandMedium
	default:
		return bandLow
	}
}

// durationBand bands a lead time or a time to restore: under elite, up to
// high (included), up to medium (included), over.
func durationBand(d, elite, high, medium time.Duration) band {
	switch {
	case d < elite:
		return bandElite
	case d <= high:
		return bandHigh
	case d <= medium:
		return bandMedium
	default:
		return bandLow
	}
}

// leadBand bands the lead time for changes.
func leadBand(d time.Duration) band {
	return durationBand(d, day, week, month)
}

// restoreBand bands the time to restore.
func restoreBand(d time.Duration) band {
	return durationBand(d, time.Hour, day, week)
}

// failureBand bands the change failure rate, in percent: each cluster's
// value is its upper bound.
func failureBand(rate float64) band {
	switch {
	case rate <= 5:
		return bandElite
	case rate <= 10:
		return bandHigh
	case rate <= 15:
		return bandMedium
	default:
		return bandLow
	}
}

// runStatus is the class and word of a ci run's result.
func runStatus(result string) (status, string) {
	switch result {
	case "success":
		return statusOK, "Success"
	case "failure":
		return statusBad, "Failure"
	case "cancelled":
		return statusNone, "Cancelled"
	default:
		return statusWarn, "Other"
	}
}

// The background rule of the security signals: a 24 h count above
// usualFloor and above usualFactor times the daily mean of the 6 days
// before is "Above usual".
const (
	usualFloor  = 20
	usualFactor = 3
)

// signalStatus is the class and word of a security signal's 24 h count;
// neither rule is bad: the alerts page, the page reports.
func signalStatus(expectedZero bool, day, week *int) (status, string) {
	switch {
	case day == nil:
		return statusNone, noData
	case expectedZero && *day == 0:
		return statusOK, "None"
	case expectedZero:
		return statusWarn, "Seen"
	}
	before := 0
	if week != nil {
		before = max(0, *week-*day)
	}
	if *day > usualFloor && float64(*day) > usualFactor*float64(before)/6 {
		return statusWarn, "Above usual"
	}
	return statusOK, "Usual"
}

// The Scorecard score's thresholds, out of 10: Scorecard's own badge turns
// from green under 7.
const (
	scoreWarnBelow = 7.0
	scoreBadBelow  = 4.0
)

// scoreStatus is the status of the Scorecard score; nil is no result yet.
func scoreStatus(score *float64) (status, string) {
	st := statusNone
	switch {
	case score == nil:
	case *score >= scoreWarnBelow:
		st = statusOK
	case *score >= scoreBadBelow:
		st = statusWarn
	default:
		st = statusBad
	}
	return st, levelWord(st)
}

// provenanceStatus is the status and word of an image's provenance as
// Kyverno verified it; nil is no report.
func provenanceStatus(verified *bool) (status, string) {
	switch {
	case verified == nil:
		return statusNone, noData
	case *verified:
		return statusOK, "Verified"
	default:
		return statusWarn, "Not verified"
	}
}
