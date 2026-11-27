package collector

import (
	"context"
	"net/http"
	"sync"
	"testing"
	"time"

	promv1 "github.com/prometheus/client_golang/api/prometheus/v1"
	"github.com/prometheus/common/model"
)

// deadlineQuerier records the time left on the context of each ALERTS range
// query of the DORA figures, the last call of a project refresh with the token.
type deadlineQuerier struct {
	Querier
	mu   sync.Mutex
	left []time.Duration
}

func (d *deadlineQuerier) QueryRange(ctx context.Context, query string, r promv1.Range) (model.Matrix, error) {
	if query == alertExpr {
		left := time.Duration(-1)
		if dl, ok := ctx.Deadline(); ok {
			left = time.Until(dl)
		}
		d.mu.Lock()
		d.left = append(d.left, left)
		d.mu.Unlock()
	}
	return d.Querier.QueryRange(ctx, query, r)
}

// TestProjectRefreshHasItsOwnDeadline guards #1606: the project refresh pages
// through a month of pull requests and ran under the 50 s cycle deadline,
// which it never met live, so no snapshot was pushed.
func TestProjectRefreshHasItsOwnDeadline(t *testing.T) {
	e := newEnv(t, zurich(2026, 11, 20, 17, 0), http.StatusNoContent)
	e.withToken(t)
	q := &deadlineQuerier{Querier: e.c.Prometheus}
	e.c.Prometheus = q
	e.c.Cycle(t.Context())
	q.mu.Lock()
	defer q.mu.Unlock()
	if len(q.left) == 0 {
		t.Fatal("the project refresh ran no DORA alert query")
	}
	for _, left := range q.left {
		if left <= cycleDeadline {
			t.Errorf("DORA alert query had %v left, want more than the %v cycle deadline", left, cycleDeadline)
		}
	}
}
