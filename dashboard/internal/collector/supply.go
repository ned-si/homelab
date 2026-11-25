package collector

import (
	"context"
	"time"

	"github.com/ned-si/homelab/dashboard/internal/snapshot"
)

// ownImagesPolicy is the Kyverno policy that checks the signature and the
// provenance of the first-party images
// (infrastructure/kyverno-policies/verify-own-images.yaml).
const ownImagesPolicy = "verify-own-images"

// podResults counts the Pods running image that have a result of the
// policy, of those whose result matches result: kube-state-metrics exports
// one series per PolicyReport result, the Pod's name in `resource`.
func podResults(image snapshot.ShownImage, result string) string {
	pods := `max by (namespace, pod) (kube_pod_container_info{image_spec=~"` + image.ImageSpec() + `"})`
	results := `max by (namespace, pod) (label_replace(kyverno_policyreport_result_info{policy="` + ownImagesPolicy +
		`"` + result + `}, "pod", "$1", "resource", "(.+)"))`
	return "count(" + pods + " * on (namespace, pod) group_left () " + results + ")"
}

// supplyChain reads, per first-party image, whether Kyverno verified the
// provenance of every running Pod that has a report: nil when none has
// one. The level is set only on that evidence (design.md, "Which SLSA
// Build level"); no namespace or Pod name leaves this function.
func supplyChain(ctx context.Context, q Querier, now time.Time) (snapshot.SupplyChain, error) {
	var s snapshot.SupplyChain
	for _, img := range snapshot.ShownImages() {
		figure := "supply_chain." + img.Name
		reported, err := optional(ctx, q, figure, podResults(img, ""), now)
		if err != nil {
			return s, err
		}
		failed, err := optional(ctx, q, figure, podResults(img, `, result!="pass"`), now)
		if err != nil {
			return s, err
		}
		out := snapshot.Image{Name: img.Name, Builder: img.Builder()}
		if reported != nil && *reported > 0 {
			v := failed == nil || *failed == 0
			out.Verified = &v
			if v {
				l := snapshot.Level
				out.Level = &l
			}
		}
		s.Images = append(s.Images, out)
	}
	s.AsOf = snapshot.FormatTime(now)
	return s, nil
}
