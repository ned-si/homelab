// Command techradar renders the tech radar page from entries.yaml, or checks
// that the committed page is current (.kiro/specs/tech-radar/design.md).
//
// Usage:
//
//	techradar render -out <dir> [-root <repo>] [-entries <file>]
//	techradar check -out <dir> [-root <repo>] [-entries <file>]
package main

import (
	"bytes"
	"context"
	"errors"
	"flag"
	"fmt"
	"io/fs"
	"os"
	"os/exec"
	"path/filepath"
	"slices"
	"strings"

	"github.com/ned-si/homelab/techradar/internal/radar"
)

func main() {
	if err := run(os.Args[1:]); err != nil {
		fmt.Fprintln(os.Stderr, "techradar:", err)
		os.Exit(1)
	}
}

func run(args []string) error {
	if len(args) == 0 || (args[0] != "render" && args[0] != "check") {
		return errors.New("usage: techradar render|check -out <dir> [-root <repo>] [-entries <file>]")
	}
	fl := flag.NewFlagSet(args[0], flag.ContinueOnError)
	out := fl.String("out", "", "directory of the rendered page")
	root := fl.String("root", "", "repository root (default: git rev-parse --show-toplevel)")
	entries := fl.String("entries", "", "entries file (default: <root>/techradar/entries.yaml)")
	if err := fl.Parse(args[1:]); err != nil {
		return err
	}
	if *out == "" {
		return errors.New("-out is required")
	}
	if *root == "" {
		top, err := exec.CommandContext(context.Background(), "git", "rev-parse", "--show-toplevel").Output()
		if err != nil {
			return fmt.Errorf("repository root: %w", err)
		}
		*root = strings.TrimSpace(string(top))
	}
	if *entries == "" {
		*entries = filepath.Join(*root, "techradar", "entries.yaml")
	}
	repo, err := radar.RepoFS(*root)
	if err != nil {
		return err
	}
	data, err := os.ReadFile(*entries) //nolint:gosec // G304, G703: the operator's own argument
	if err != nil {
		return err
	}
	r, err := radar.Parse(data, repo)
	if err != nil {
		return err
	}
	files, err := radar.Render(r, repo)
	if err != nil {
		return err
	}
	if args[0] == "render" {
		if err := os.MkdirAll(*out, 0o750); err != nil { //nolint:gosec // G703: the operator's own argument
			return err
		}
	}
	dir, err := os.OpenRoot(*out)
	if err != nil {
		return err
	}
	defer func() { _ = dir.Close() }() // read or written already; nothing to lose
	if args[0] == "check" {
		return check(dir, files)
	}
	for name, b := range files {
		if err := dir.WriteFile(name, b, 0o644); err != nil {
			return err
		}
	}
	return nil
}

// check fails when dir differs from a fresh render: a changed, missing or
// extra file.
func check(dir *os.Root, files radar.Files) error {
	var stale []string
	for name, want := range files {
		got, err := dir.ReadFile(name)
		if err != nil || !bytes.Equal(got, want) {
			stale = append(stale, name)
		}
	}
	list, err := fs.ReadDir(dir.FS(), ".")
	if err != nil {
		return err
	}
	for _, f := range list {
		if _, ok := files[f.Name()]; !ok {
			stale = append(stale, f.Name()+" (not rendered)")
		}
	}
	if len(stale) > 0 {
		slices.Sort(stale)
		return fmt.Errorf("%s is stale: %s; run task techradar:render", dir.Name(), strings.Join(stale, ", "))
	}
	return nil
}
