package web

import (
	"encoding/json"
	"errors"
	"io"
	"mime"
	"net/http"
	"time"

	"github.com/ned-si/homelab/dashboard/internal/snapshot"
)

const (
	// maxAge and maxAhead bound generated_at of an accepted push, so a
	// replayed or rolled-back snapshot is refused.
	maxAge   = 5 * time.Minute
	maxAhead = 1 * time.Minute
)

// Push returns the handler of the internal push port: POST /v1/snapshot
// only, anything else 404.
func (s *Server) Push() http.Handler {
	return http.HandlerFunc(s.receive)
}

func (s *Server) refuse(w http.ResponseWriter, code int, reason string) {
	s.metrics.PushRejected.WithLabelValues(reason).Inc()
	s.logger.Warn("push refused", "reason", reason)
	http.Error(w, http.StatusText(code), code)
}

func (s *Server) receive(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost || r.URL.Path != "/v1/snapshot" {
		http.NotFound(w, r)
		return
	}
	if r.ContentLength > snapshot.MaxSize {
		s.refuse(w, http.StatusRequestEntityTooLarge, "size")
		return
	}
	if mt, _, err := mime.ParseMediaType(r.Header.Get("Content-Type")); err != nil || mt != "application/json" {
		s.refuse(w, http.StatusBadRequest, "content_type")
		return
	}
	body, err := io.ReadAll(http.MaxBytesReader(w, r.Body, snapshot.MaxSize))
	if err != nil {
		var tooLarge *http.MaxBytesError
		if errors.As(err, &tooLarge) {
			s.refuse(w, http.StatusRequestEntityTooLarge, "size")
			return
		}
		http.Error(w, "read error", http.StatusBadRequest)
		return
	}
	// The signature first: an unsigned request costs one check and nothing
	// else, and the body is not parsed.
	if !snapshot.Verify(*s.keys.Load(), r.Header.Get(snapshot.SignatureHeader), body) {
		s.refuse(w, http.StatusUnauthorized, "signature")
		return
	}
	var head struct {
		GeneratedAt string `json:"generated_at"`
	}
	if err := json.Unmarshal(body, &head); err != nil {
		s.refuse(w, http.StatusBadRequest, "schema")
		return
	}
	generated, err := snapshot.ParseTime(head.GeneratedAt)
	if err != nil {
		s.refuse(w, http.StatusBadRequest, "schema")
		return
	}
	now := s.now()
	if now.Sub(generated) > maxAge || generated.Sub(now) > maxAhead {
		s.refuse(w, http.StatusConflict, "replay")
		return
	}
	snap, err := snapshot.Validate(body)
	if err != nil {
		reason := "schema"
		if errors.Is(err, snapshot.ErrNotShown) {
			reason = "allowlist"
		}
		s.refuse(w, http.StatusBadRequest, reason)
		return
	}
	next := &held{snap: snap, body: body, generated: generated}
	for {
		cur := s.current.Load()
		if cur != nil && !generated.After(cur.generated) {
			s.refuse(w, http.StatusConflict, "replay")
			return
		}
		if s.current.CompareAndSwap(cur, next) {
			break
		}
	}
	w.WriteHeader(http.StatusNoContent)
}
