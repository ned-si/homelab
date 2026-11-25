package collector

import (
	"strings"
	"testing"
	"time"

	"github.com/google/go-cmp/cmp"

	"github.com/ned-si/homelab/dashboard/internal/snapshot"
)

// The level is claimed only when every reporting Pod passed; no report is
// no data (design.md, "Which SLSA Build level").
func TestSupplyChain(t *testing.T) {
	yes, no := true, false
	l2 := snapshot.Level
	tests := []struct {
		name             string
		reported, failed map[string]float64
		want             []snapshot.Image
	}{
		{"both verified", map[string]float64{"homelab-dashboard": 2, "homelab-site": 1}, map[string]float64{}, []snapshot.Image{
			{Name: "homelab-dashboard", Level: &l2, Verified: &yes, Builder: "GitHub-hosted runner, dashboard-publish.yaml on main"},
			{Name: "homelab-site", Level: &l2, Verified: &yes, Builder: "GitHub-hosted runner, site-publish.yaml on main"},
		}},
		{"one Pod fails", map[string]float64{"homelab-dashboard": 2, "homelab-site": 2}, map[string]float64{"homelab-site": 1}, []snapshot.Image{
			{Name: "homelab-dashboard", Level: &l2, Verified: &yes, Builder: "GitHub-hosted runner, dashboard-publish.yaml on main"},
			{Name: "homelab-site", Verified: &no, Builder: "GitHub-hosted runner, site-publish.yaml on main"},
		}},
		{"no report", map[string]float64{"homelab-dashboard": 0}, map[string]float64{}, []snapshot.Image{
			{Name: "homelab-dashboard", Builder: "GitHub-hosted runner, dashboard-publish.yaml on main"},
			{Name: "homelab-site", Builder: "GitHub-hosted runner, site-publish.yaml on main"},
		}},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			e := newEnv(t, time.Date(2026, 11, 25, 15, 0, 0, 0, snapshot.Zurich), 204)
			e.fake.reported, e.fake.failed = tc.reported, tc.failed
			s := e.push(t)
			if diff := cmp.Diff(tc.want, s.SupplyChain.Images); diff != "" {
				t.Errorf("images (-want +got):\n%s", diff)
			}
			if s.SupplyChain.AsOf != s.GeneratedAt {
				t.Errorf("as_of %s, want generated_at %s", s.SupplyChain.AsOf, s.GeneratedAt)
			}
		})
	}
}

// Each query joins the image's running Pods with the policy's results by
// Pod, so another policy or image, or a Pod that has stopped, never counts.
func TestPodResultsQuery(t *testing.T) {
	q := podResults(snapshot.ShownImages()[1], `, result!="pass"`)
	for _, want := range []string{
		`kube_pod_container_info{image_spec=~"ghcr\\.io/ned-si/homelab-site(:[^@]+)?@sha256:[0-9a-f]{64}"}`,
		`kyverno_policyreport_result_info{policy="verify-own-images", result!="pass"}`,
		`(max by (namespace, pod) (kube_pod_status_phase{phase="Running"}) == 1)`,
		`* on (namespace, pod) group_left ()`,
		`"pod", "$1", "resource", "(.+)"`,
	} {
		if !strings.Contains(q, want) {
			t.Errorf("%s lacks %s", q, want)
		}
	}
}
