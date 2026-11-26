// Command drumcharts validates the site data of charts.nedsi.io and renders
// its pages (.kiro/specs/drum-charts-site/design.md).
//
// Usage:
//
//	drumcharts render -data <dir> -out <dir>
//
// -data is the /charts directory of the ghcr.io/ned-si/drum-charts image;
// -out must not exist. On any error nothing is written and every broken rule
// is printed, one `<file>: <rule>` line each.
package main

import (
	"errors"
	"flag"
	"fmt"
	"os"

	"github.com/ned-si/homelab/drumcharts/internal/site"
)

func main() {
	if err := run(os.Args[1:]); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}

func run(args []string) error {
	if len(args) == 0 || args[0] != "render" {
		return errors.New("usage: drumcharts render -data <dir> -out <dir>")
	}
	fl := flag.NewFlagSet("render", flag.ContinueOnError)
	data := fl.String("data", "", "directory of the site data")
	out := fl.String("out", "", "directory to render into; must not exist")
	if err := fl.Parse(args[1:]); err != nil {
		return err
	}
	if *data == "" || *out == "" {
		return errors.New("-data and -out are required")
	}
	d, err := site.Load(*data)
	if err != nil {
		return err
	}
	files, err := site.Render(d)
	if err != nil {
		return err
	}
	return site.Write(files, *out)
}
