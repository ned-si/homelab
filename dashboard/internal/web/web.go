// Package web is the public role: it accepts signed snapshots on the
// internal push port, keeps the last good one in memory and renders
// https://homelab.nedsi.io/ on every request. It holds no credential and makes
// no outbound connection (.kiro/specs/homelab-dashboard/design.md, "Web").
package web

import (
	"context"
	"crypto/ed25519"
	"crypto/sha256"
	"embed"
	"encoding/base64"
	"encoding/hex"
	"fmt"
	"html/template"
	"log/slog"
	"os"
	"slices"
	"sync/atomic"
	"time"

	"github.com/prometheus/client_golang/prometheus"

	"github.com/ned-si/homelab/dashboard/internal/metrics"
	"github.com/ned-si/homelab/dashboard/internal/snapshot"
)

// readyAfter is when a web pod with no snapshot turns ready anyway, so the
// page still comes up while the collector is down.
const readyAfter = 120 * time.Second

// keysEvery is how often the public keys are re-read, so a rotation needs no
// release.
const keysEvery = 30 * time.Second

//go:embed templates/*.html
var templateFS embed.FS

//go:embed assets/layout.css
var layoutCSS []byte

//go:embed assets/dashboard.css
var dashboardCSS []byte

// The palette copies (site/assets/css/theme-*.css), served as /theme.css by
// the cookie (.kiro/specs/site-theme-language/design.md#go-web-role).
var (
	//go:embed assets/theme-dark.css
	themeDark []byte
	//go:embed assets/theme-light.css
	themeLight []byte
)

// css is the one stylesheet: the shared layout (a copy of
// site/assets/css/layout.css), then the dashboard's own rules.
var css = slices.Concat(layoutCSS, dashboardCSS)

// held is the snapshot served: the validated document and its exact body.
type held struct {
	snap      *snapshot.Snapshot
	body      []byte
	generated time.Time
}

// Server holds the current snapshot and the push keys.
type Server struct {
	logger  *slog.Logger
	metrics *metrics.Web
	now     func() time.Time
	start   time.Time

	keys    atomic.Pointer[[]ed25519.PublicKey]
	current atomic.Pointer[held]

	page         *template.Template
	notFound     *template.Template
	cssPath      string
	cssIntegrity string
}

// Options configures a Server.
type Options struct {
	Logger *slog.Logger
	// Registry gets the web role's metrics.
	Registry prometheus.Registerer
	// Now is the clock; time.Now when nil.
	Now func() time.Time
	// Keys are the public keys a push may be signed with.
	Keys []ed25519.PublicKey
}

// New returns a Server with no snapshot.
func New(o Options) (*Server, error) {
	s := &Server{logger: o.Logger, now: o.Now}
	if s.now == nil {
		s.now = time.Now
	}
	s.start = s.now()
	s.SetKeys(o.Keys)
	var err error
	if s.page, err = template.New("page.html").Funcs(template.FuncMap{"em": em}).ParseFS(templateFS, "templates/page.html", "templates/layout.html"); err != nil {
		return nil, fmt.Errorf("page template: %w", err)
	}
	if s.notFound, err = template.ParseFS(templateFS, "templates/notfound.html", "templates/layout.html"); err != nil {
		return nil, fmt.Errorf("not found template: %w", err)
	}
	sum := sha256.Sum256(css)
	s.cssPath = "/assets/dashboard." + hex.EncodeToString(sum[:])[:8] + ".css"
	s.cssIntegrity = "sha256-" + base64.StdEncoding.EncodeToString(sum[:])
	s.metrics = metrics.NewWeb(o.Registry, s.SnapshotAge, s.BlockAge)
	return s, nil
}

// SetKeys replaces the public keys pushes are verified against.
func (s *Server) SetKeys(keys []ed25519.PublicKey) {
	s.keys.Store(&keys)
}

// WatchKeys re-reads the public keys from path every 30 s until ctx is done.
// A file that fails to parse keeps the keys already held.
func (s *Server) WatchKeys(ctx context.Context, path string) {
	t := time.NewTicker(keysEvery)
	defer t.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-t.C:
			keys, err := LoadKeys(path)
			if err != nil {
				s.logger.Error("public keys not reloaded, previous keys kept", "error", err.Error())
				continue
			}
			s.SetKeys(keys)
		}
	}
}

// LoadKeys reads the PEM public keys file.
func LoadKeys(path string) ([]ed25519.PublicKey, error) {
	b, err := os.ReadFile(path) //nolint:gosec // G304: the path is the mounted ConfigMap, set by the operator.
	if err != nil {
		return nil, err
	}
	return snapshot.ParsePublicKeys(b)
}

// Ready reports whether the pod should take traffic: it holds a snapshot, or
// has waited 120 s for one.
func (s *Server) Ready() bool {
	return s.current.Load() != nil || s.now().Sub(s.start) >= readyAfter
}

// SnapshotAge is now minus generated_at of the snapshot served, or minus the
// process start without one, in seconds.
func (s *Server) SnapshotAge() float64 {
	from := s.start
	if h := s.current.Load(); h != nil {
		from = h.generated
	}
	return s.now().Sub(from).Seconds()
}

// BlockAge is now minus as_of of the block (availability, certificates,
// cluster, project or security) of the snapshot served, or minus the process start
// without one, in seconds.
func (s *Server) BlockAge(block string) float64 {
	from := s.start
	if h := s.current.Load(); h != nil {
		asOf := map[string]string{
			"availability": h.snap.Availability.AsOf,
			"certificates": h.snap.Certificates.AsOf,
			"cluster":      h.snap.Cluster.AsOf,
			"project":      h.snap.Project.AsOf,
			"security":     h.snap.Security.AsOf,
		}[block]
		if t, err := snapshot.ParseTime(asOf); err == nil {
			from = t
		}
	}
	return s.now().Sub(from).Seconds()
}
