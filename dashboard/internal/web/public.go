package web

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"net/http"
	"regexp"
	"strconv"
	"strings"
	"time"

	"github.com/ned-si/homelab/dashboard/internal/metrics"
	"github.com/ned-si/homelab/dashboard/internal/snapshot"
)

// headers are set on every response of the public port; the HTTPRoute sets
// the same values (apps/website/httproute.yaml).
var headers = [][2]string{
	{"Content-Security-Policy", "default-src 'none'; style-src 'self'; img-src 'self'; font-src 'self'; " +
		"base-uri 'none'; form-action 'none'; frame-ancestors 'none'; upgrade-insecure-requests"},
	{"Strict-Transport-Security", "max-age=31536000; includeSubDomains"},
	{"X-Content-Type-Options", "nosniff"},
	{"X-Frame-Options", "DENY"},
	{"Referrer-Policy", "strict-origin-when-cross-origin"},
	{"Permissions-Policy", "camera=(), microphone=(), geolocation=(), payment=(), usb=()"},
	{"Cross-Origin-Opener-Policy", "same-origin"},
}

// recorder keeps the status and size for the access log and the metrics.
type recorder struct {
	http.ResponseWriter
	status int
	bytes  int
}

func (r *recorder) WriteHeader(code int) {
	if r.status == 0 {
		r.status = code
	}
	r.ResponseWriter.WriteHeader(code)
}

func (r *recorder) Write(b []byte) (int, error) {
	if r.status == 0 {
		r.status = http.StatusOK
	}
	n, err := r.ResponseWriter.Write(b)
	r.bytes += n
	return n, err
}

// Public returns the handler of the public port.
func (s *Server) Public() http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		start := time.Now()
		rec := &recorder{ResponseWriter: w}
		for _, h := range headers {
			w.Header().Set(h[0], h[1])
		}
		s.route(rec, r)
		d := time.Since(start)
		if rec.status == 0 {
			rec.status = http.StatusOK
		}
		s.metrics.Requests.WithLabelValues(strconv.Itoa(rec.status), metrics.Method(r.Method)).Inc()
		s.metrics.Duration.Observe(d.Seconds())
		// No client address, user agent, referrer or query string, ever.
		s.logger.Info("request",
			"method", r.Method,
			"path", r.URL.Path,
			"status", rec.status,
			"bytes", rec.bytes,
			"duration_ms", float64(d.Microseconds())/1000)
	})
}

func (s *Server) route(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet && r.Method != http.MethodHead {
		w.Header().Set("Allow", "GET, HEAD")
		http.Error(w, http.StatusText(http.StatusMethodNotAllowed), http.StatusMethodNotAllowed)
		return
	}
	switch r.URL.Path {
	case "/":
		s.servePage(w, r)
	case "/snapshot.json":
		h := s.current.Load()
		if h == nil {
			s.serveNotFound(w)
			return
		}
		w.Header().Set("Cache-Control", "no-cache")
		serve(w, r, "application/json", h.body)
	case s.cssPath:
		w.Header().Set("Cache-Control", "public, max-age=31536000, immutable")
		serve(w, r, "text/css; charset=utf-8", css)
	case "/theme.css":
		w.Header().Set("Cache-Control", "no-store")
		w.Header().Set("Vary", "Cookie")
		body := themeDark
		if c, err := r.Cookie("theme"); err == nil && c.Value == "light" {
			body = themeLight
		}
		serve(w, r, "text/css; charset=utf-8", body)
	default:
		if strings.HasPrefix(r.URL.Path, "/set-theme/") {
			s.setTheme(w, r)
			return
		}
		s.serveNotFound(w)
	}
}

// backPath is a path the theme endpoint may redirect to: the characters of
// every path the four hosts serve, nothing that could add a header or read
// as another host.
var backPath = regexp.MustCompile(`^/[A-Za-z0-9._~/-]*$`)

// setTheme answers /set-theme/<light|dark><path> with a 303 to <path> and,
// on a click, sets or deletes the theme cookie, as nginx does
// (.kiro/specs/site-theme-language/design.md#how-the-theme-is-served).
func (s *Server) setTheme(w http.ResponseWriter, r *http.Request) {
	theme, back, ok := strings.Cut(strings.TrimPrefix(r.URL.Path, "/set-theme/"), "/")
	back = "/" + back
	if !ok || (theme != "light" && theme != "dark") || !backPath.MatchString(back) || strings.HasPrefix(back, "//") {
		s.serveNotFound(w)
		return
	}
	if themeClick(r) {
		c := &http.Cookie{
			Name: "theme", Domain: "nedsi.io", Path: "/",
			Secure: true, HttpOnly: true, SameSite: http.SameSiteLaxMode,
		}
		if theme == "light" {
			c.Value, c.MaxAge = "light", 31536000
		} else {
			c.MaxAge = -1 // Max-Age=0: delete it
		}
		http.SetCookie(w, c)
	}
	w.Header().Set("Cache-Control", "no-store")
	w.Header().Set("Location", back)
	w.WriteHeader(http.StatusSeeOther)
}

// themeClick reports whether the request is the reader's own click or typed
// address: not a cross-site navigation, not a prefetch or prerender. A
// browser without Fetch Metadata counts as a click.
func themeClick(r *http.Request) bool {
	if _, ok := r.Header["Sec-Purpose"]; ok {
		return false
	}
	switch r.Header.Get("Sec-Fetch-Site") {
	case "", "same-origin", "same-site", "none":
		return true
	}
	return false
}

func (s *Server) servePage(w http.ResponseWriter, r *http.Request) {
	var snap *snapshot.Snapshot
	if h := s.current.Load(); h != nil {
		snap = h.snap
	}
	d, err := view(snap, s.now())
	if err == nil {
		d.CSS, d.CSSIntegrity = s.cssPath, s.cssIntegrity
		var b bytes.Buffer
		if err = s.page.Execute(&b, d); err == nil {
			w.Header().Set("Cache-Control", "no-cache")
			serve(w, r, "text/html; charset=utf-8", b.Bytes())
			return
		}
	}
	s.logger.Error("render failed", "error", err.Error())
	http.Error(w, http.StatusText(http.StatusInternalServerError), http.StatusInternalServerError)
}

func (s *Server) serveNotFound(w http.ResponseWriter) {
	var b bytes.Buffer
	d := &pageData{Title: "Page not found", CSS: s.cssPath, CSSIntegrity: s.cssIntegrity}
	if err := s.notFound.Execute(&b, d); err != nil {
		s.logger.Error("render failed", "error", err.Error())
		http.Error(w, http.StatusText(http.StatusNotFound), http.StatusNotFound)
		return
	}
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	w.Header().Set("Content-Length", strconv.Itoa(b.Len()))
	w.WriteHeader(http.StatusNotFound)
	_, _ = w.Write(b.Bytes())
}

// serve writes body with an ETag, or 304 when If-None-Match has it.
func serve(w http.ResponseWriter, r *http.Request, contentType string, body []byte) {
	sum := sha256.Sum256(body)
	etag := `"` + hex.EncodeToString(sum[:16]) + `"`
	w.Header().Set("ETag", etag)
	if matches(r.Header.Get("If-None-Match"), etag) {
		w.WriteHeader(http.StatusNotModified)
		return
	}
	w.Header().Set("Content-Type", contentType)
	w.Header().Set("Content-Length", strconv.Itoa(len(body)))
	w.WriteHeader(http.StatusOK)
	if r.Method != http.MethodHead {
		_, _ = w.Write(body)
	}
}

func matches(ifNoneMatch, etag string) bool {
	for _, t := range strings.Split(ifNoneMatch, ",") {
		t = strings.TrimPrefix(strings.TrimSpace(t), "W/")
		if t == etag || t == "*" {
			return true
		}
	}
	return false
}
