// Command pushfixture feeds a local web role in CI, for the smoke test of
// dashboard-publish and the screenshot check:
//
//	pushfixture keygen <dir>
//	pushfixture push [--fixture <file>] [--want <status>] <private-key> <url>
//
// keygen writes a throwaway Ed25519 pair, <dir>/private-key and
// <dir>/public-keys, so no test key lives in git. push moves every time of
// the fixture by the same amount so generated_at is now, signs it and posts
// it to <url>/v1/snapshot; it exits 1 unless the status is --want.
package main

import (
	"bytes"
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"crypto/x509"
	"encoding/json"
	"encoding/pem"
	"errors"
	"flag"
	"fmt"
	"io"
	"net/http"
	"os"
	"time"

	"github.com/ned-si/homelab/dashboard/internal/snapshot"
)

func main() {
	if err := run(context.Background(), os.Args[1:], os.Stdout); err != nil {
		_, _ = fmt.Fprintln(os.Stderr, "pushfixture:", err)
		os.Exit(1)
	}
}

func run(ctx context.Context, args []string, stdout io.Writer) error {
	if len(args) == 0 {
		return errors.New("usage: pushfixture keygen|push")
	}
	switch args[0] {
	case "keygen":
		if len(args) != 2 {
			return errors.New("usage: pushfixture keygen <dir>")
		}
		return keygen(args[1])
	case "push":
		return push(ctx, args[1:], stdout)
	default:
		return fmt.Errorf("unknown command %q", args[0])
	}
}

func keygen(dir string) error {
	pub, key, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		return err
	}
	der, err := x509.MarshalPKCS8PrivateKey(key)
	if err != nil {
		return err
	}
	pubDER, err := x509.MarshalPKIXPublicKey(pub)
	if err != nil {
		return err
	}
	files := []struct {
		name  string
		block *pem.Block
	}{
		{"private-key", &pem.Block{Type: "PRIVATE KEY", Bytes: der}},
		{"public-keys", &pem.Block{Type: "PUBLIC KEY", Bytes: pubDER}},
	}
	root, err := os.OpenRoot(dir)
	if err != nil {
		return err
	}
	defer func() { _ = root.Close() }()
	for _, f := range files {
		if err := root.WriteFile(f.name, pem.EncodeToMemory(f.block), 0o600); err != nil {
			return err
		}
	}
	return nil
}

func push(ctx context.Context, args []string, stdout io.Writer) error {
	fs := flag.NewFlagSet("push", flag.ContinueOnError)
	fixture := fs.String("fixture", "internal/web/testdata/snapshot.json", "snapshot to push")
	want := fs.Int("want", http.StatusNoContent, "expected status")
	if err := fs.Parse(args); err != nil {
		return err
	}
	if fs.NArg() != 2 {
		return errors.New("usage: pushfixture push [flags] <private-key> <url>")
	}
	keyPEM, err := os.ReadFile(fs.Arg(0))
	if err != nil {
		return err
	}
	key, err := snapshot.ParsePrivateKey(keyPEM)
	if err != nil {
		return err
	}
	raw, err := os.ReadFile(*fixture)
	if err != nil {
		return err
	}
	body, err := moveToNow(raw, time.Now())
	if err != nil {
		return fmt.Errorf("%s: %w", *fixture, err)
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, fs.Arg(1)+"/v1/snapshot", bytes.NewReader(body))
	if err != nil {
		return err
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set(snapshot.SignatureHeader, snapshot.Sign(key, body))
	resp, err := (&http.Client{Timeout: 10 * time.Second}).Do(req)
	if err != nil {
		return err
	}
	defer func() { _ = resp.Body.Close() }()
	_, _ = io.Copy(io.Discard, resp.Body)
	_, _ = fmt.Fprintln(stdout, resp.StatusCode)
	if resp.StatusCode != *want {
		return fmt.Errorf("status %d, want %d", resp.StatusCode, *want)
	}
	return nil
}

// moveToNow shifts generated_at, the as_of times and daily.computed_at by
// now minus generated_at, sets daily.covers to the day before computed_at
// and availability.days to the 30 days ending today, so the web role
// accepts the push and shows nothing stale.
func moveToNow(raw []byte, now time.Time) ([]byte, error) {
	var doc map[string]any
	if err := json.Unmarshal(raw, &doc); err != nil {
		return nil, err
	}
	generated, err := timeAt(doc, "generated_at")
	if err != nil {
		return nil, err
	}
	delta := now.Truncate(time.Second).Sub(generated)
	doc["generated_at"] = snapshot.FormatTime(generated.Add(delta))
	for _, block := range []string{"availability", "certificates", "cluster", "project"} {
		m, ok := doc[block].(map[string]any)
		if !ok {
			return nil, fmt.Errorf("no %s block", block)
		}
		t, err := timeAt(m, "as_of")
		if err != nil {
			return nil, fmt.Errorf("%s: %w", block, err)
		}
		m["as_of"] = snapshot.FormatTime(t.Add(delta))
	}
	days := make([]string, snapshot.Days)
	today := snapshot.Day(generated.Add(delta))
	for i := range days {
		days[i] = snapshot.AddDays(today, i-(snapshot.Days-1)).Format(snapshot.DateLayout)
	}
	doc["availability"].(map[string]any)["days"] = days
	daily, ok := doc["daily"].(map[string]any)
	if !ok {
		return nil, errors.New("no daily block")
	}
	computed, err := timeAt(daily, "computed_at")
	if err != nil {
		return nil, fmt.Errorf("daily: %w", err)
	}
	computed = computed.Add(delta)
	daily["computed_at"] = snapshot.FormatTime(computed)
	daily["covers"] = snapshot.AddDays(snapshot.Day(computed), -1).Format(snapshot.DateLayout)
	return json.Marshal(doc)
}

func timeAt(m map[string]any, key string) (time.Time, error) {
	s, ok := m[key].(string)
	if !ok {
		return time.Time{}, fmt.Errorf("no %s", key)
	}
	return snapshot.ParseTime(s)
}
