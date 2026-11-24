// Command homelab-dashboard is the public dashboard of the homelab, one
// binary with two roles:
//
//	homelab-dashboard collect [--once] [--dry-run]
//	homelab-dashboard web
//	homelab-dashboard version
//
// Design: .kiro/specs/homelab-dashboard/design.md.
package main

import (
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"runtime"
	"syscall"
	"time"

	"github.com/ned-si/homelab/dashboard/internal/collector"
	"github.com/ned-si/homelab/dashboard/internal/metrics"
	"github.com/ned-si/homelab/dashboard/internal/snapshot"
	"github.com/ned-si/homelab/dashboard/internal/web"
)

// version is the git commit, set at build time with -ldflags "-X main.version=...".
var version = "dev"

const shutdownTimeout = 10 * time.Second

func main() {
	os.Exit(run(os.Args[1:], os.Stdout, os.Stderr))
}

func run(args []string, stdout, stderr io.Writer) int {
	if len(args) == 0 {
		_, _ = fmt.Fprintln(stderr, "usage: homelab-dashboard collect|web|version [flags]")
		return 2
	}
	logger := slog.New(slog.NewJSONHandler(stdout, nil))
	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGTERM, os.Interrupt)
	defer stop()
	var err error
	switch args[0] {
	case "version":
		_, _ = fmt.Fprintln(stdout, version)
		return 0
	case "collect":
		err = collect(ctx, args[1:], stdout, stderr, logger)
	case "web":
		err = serveWeb(ctx, args[1:], stderr, logger)
	default:
		_, _ = fmt.Fprintf(stderr, "homelab-dashboard: unknown command %q\n", args[0])
		return 2
	}
	if errors.Is(err, flag.ErrHelp) {
		return 0
	}
	if err != nil {
		// stderr: a dry run's stdout carries the document only.
		slog.New(slog.NewJSONHandler(stderr, nil)).Error("exit", "error", err.Error())
		return 1
	}
	return 0
}

func env(name, fallback string) string {
	if v := os.Getenv(name); v != "" {
		return v
	}
	return fallback
}

func newServer(addr string, h http.Handler) *http.Server {
	return &http.Server{
		Addr:              addr,
		Handler:           h,
		ReadHeaderTimeout: 5 * time.Second,
		ReadTimeout:       10 * time.Second,
		WriteTimeout:      10 * time.Second,
		IdleTimeout:       60 * time.Second,
		MaxHeaderBytes:    8 << 10,
	}
}

// serve runs the servers until ctx is done or one fails, then shuts them
// all down within shutdownTimeout.
func serve(ctx context.Context, servers ...*http.Server) error {
	errs := make(chan error, len(servers))
	for _, s := range servers {
		go func() {
			if err := s.ListenAndServe(); !errors.Is(err, http.ErrServerClosed) {
				errs <- fmt.Errorf("%s: %w", s.Addr, err)
			}
		}()
	}
	var err error
	select {
	case <-ctx.Done():
	case err = <-errs:
	}
	sctx, cancel := context.WithTimeout(context.WithoutCancel(ctx), shutdownTimeout)
	defer cancel()
	for _, s := range servers {
		err = errors.Join(err, s.Shutdown(sctx))
	}
	return err
}

func collect(ctx context.Context, args []string, stdout, stderr io.Writer, logger *slog.Logger) error {
	fs := flag.NewFlagSet("collect", flag.ContinueOnError)
	fs.SetOutput(stderr)
	once := fs.Bool("once", false, "run one collection and exit")
	dryRun := fs.Bool("dry-run", false, "print the snapshot instead of pushing it")
	promURL := fs.String("prometheus-url", env("PROM_URL", "http://kube-prometheus-stack-prometheus.monitoring.svc:9090"), "Prometheus base URL")
	githubAPI := fs.String("github-api", env("GITHUB_API", "https://api.github.com"), "GitHub API base URL")
	tokenFile := fs.String("github-token-file", "/var/run/secrets/github/token", "GitHub token; absent means anonymous calls")
	keyFile := fs.String("push-key-file", "/var/run/secrets/push/private-key", "Ed25519 private key, PKCS #8 PEM")
	pushHost := fs.String("push-service", "homelab-dashboard-web-push.homelab-dashboard.svc", "headless Service of the web pods")
	pushPort := fs.Int("push-port", 9465, "push port of the web pods")
	metricsAddr := fs.String("metrics-addr", ":9464", "metrics, health and readiness")
	if err := fs.Parse(args); err != nil {
		return err
	}
	if *dryRun && !*once {
		return errors.New("--dry-run needs --once")
	}

	prom, err := collector.NewPrometheus(*promURL)
	if err != nil {
		return err
	}
	reg := metrics.NewRegistry("collector", version)
	m := metrics.NewCollector(reg)
	httpClient := &http.Client{Timeout: collector.HTTPTimeout}
	c := &collector.Collector{
		Prometheus: prom,
		GitHub: &collector.GitHub{
			BaseURL:   *githubAPI,
			Repo:      "ned-si/homelab",
			Workflow:  "ci.yaml",
			TokenFile: *tokenFile,
			UserAgent: "homelab-dashboard/" + version,
			Client:    httpClient,
			Remaining: func(n int) { m.RateLimitRemaining.Set(float64(n)) },
		},
		Pusher: &collector.Pusher{
			Targets: collector.HeadlessTargets(*pushHost, *pushPort),
			Client:  httpClient,
		},
		Metrics: m,
		Logger:  logger,
		Now:     time.Now,
	}

	if *dryRun {
		// stdout carries the document only.
		c.Logger = slog.New(slog.NewJSONHandler(stderr, nil))
		return dryRunOnce(ctx, c, stdout)
	}
	logger.Info("starting", "role", "collector", "version", version, "goversion", runtime.Version())
	keyPEM, err := os.ReadFile(*keyFile)
	if err != nil {
		return fmt.Errorf("read the push key: %w", err)
	}
	if c.Key, err = snapshot.ParsePrivateKey(keyPEM); err != nil {
		return fmt.Errorf("push key: %w", err)
	}
	if *once {
		_, body, err := c.Collect(ctx, time.Now())
		if err != nil {
			return err
		}
		if !c.Push(ctx, body) {
			return errors.New("not every web pod accepted the snapshot")
		}
		return nil
	}
	go c.Run(ctx)
	return serve(ctx, newServer(*metricsAddr, metrics.Handler(reg, c.Ready)))
}

func dryRunOnce(ctx context.Context, c *collector.Collector, stdout io.Writer) error {
	s, _, err := c.Collect(ctx, time.Now())
	if err != nil {
		return err
	}
	enc := json.NewEncoder(stdout)
	enc.SetIndent("", "  ")
	return enc.Encode(s)
}

func serveWeb(ctx context.Context, args []string, stderr io.Writer, logger *slog.Logger) error {
	fs := flag.NewFlagSet("web", flag.ContinueOnError)
	fs.SetOutput(stderr)
	listen := fs.String("listen", ":8080", "public port")
	pushListen := fs.String("push-listen", ":9465", "internal push port")
	metricsAddr := fs.String("metrics-addr", ":9464", "metrics, health and readiness")
	keysFile := fs.String("public-keys", "/etc/homelab-dashboard/public-keys", "Ed25519 public keys, PKIX PEM")
	if err := fs.Parse(args); err != nil {
		return err
	}
	logger.Info("starting", "role", "web", "version", version, "goversion", runtime.Version())
	keys, err := web.LoadKeys(*keysFile)
	if err != nil {
		return fmt.Errorf("public keys: %w", err)
	}
	reg := metrics.NewRegistry("web", version)
	s, err := web.New(web.Options{Logger: logger, Registry: reg, Keys: keys})
	if err != nil {
		return err
	}
	go s.WatchKeys(ctx, *keysFile)
	return serve(ctx,
		newServer(*listen, s.Public()),
		newServer(*pushListen, s.Push()),
		newServer(*metricsAddr, metrics.Handler(reg, s.Ready)),
	)
}
