package collector

import (
	"bytes"
	"context"
	"fmt"
	"io"
	"net"
	"net/http"
	"strconv"

	"github.com/ned-si/homelab/dashboard/internal/snapshot"
)

// PushPath is where a web pod accepts snapshots.
const PushPath = "/v1/snapshot"

// Pusher posts a signed snapshot to every web pod.
type Pusher struct {
	// Targets returns the base URL of every web pod.
	Targets func(ctx context.Context) ([]string, error)
	// Client makes the calls; its Timeout bounds each one.
	Client *http.Client
}

// HeadlessTargets resolves the headless Service host to one base URL per
// pod address, ready or not, on port.
func HeadlessTargets(host string, port int) func(ctx context.Context) ([]string, error) {
	return func(ctx context.Context) ([]string, error) {
		addrs, err := net.DefaultResolver.LookupHost(ctx, host)
		if err != nil {
			return nil, err
		}
		out := make([]string, len(addrs))
		for i, a := range addrs {
			out[i] = "http://" + net.JoinHostPort(a, strconv.Itoa(port))
		}
		return out, nil
	}
}

// PushResult is the outcome of one push.
type PushResult struct {
	Target string
	// Result is accepted, rejected or error, the push_total label.
	Result string
	Err    error
}

// Push posts body with its signature to every target.
func (p *Pusher) Push(ctx context.Context, body []byte, signature string) ([]PushResult, error) {
	targets, err := p.Targets(ctx)
	if err != nil {
		return nil, fmt.Errorf("resolve the web pods: %w", err)
	}
	out := make([]PushResult, 0, len(targets))
	for _, t := range targets {
		out = append(out, p.pushOne(ctx, t, body, signature))
	}
	return out, nil
}

func (p *Pusher) pushOne(ctx context.Context, target string, body []byte, signature string) PushResult {
	res := PushResult{Target: target}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, target+PushPath, bytes.NewReader(body))
	if err != nil {
		res.Result, res.Err = "error", err
		return res
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set(snapshot.SignatureHeader, signature)
	resp, err := p.Client.Do(req)
	if err != nil {
		res.Result, res.Err = "error", err
		return res
	}
	defer func() { _ = resp.Body.Close() }()
	_, _ = io.Copy(io.Discard, io.LimitReader(resp.Body, 4<<10))
	if resp.StatusCode != http.StatusNoContent {
		res.Result, res.Err = "rejected", fmt.Errorf("status %d", resp.StatusCode)
		return res
	}
	res.Result = "accepted"
	return res
}
