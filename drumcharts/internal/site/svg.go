package site

import (
	"bytes"
	"encoding/xml"
	"errors"
	"fmt"
	"io"
	"math"
	"regexp"
	"slices"
	"strconv"
	"strings"
)

const (
	svgNS   = "http://www.w3.org/2000/svg"
	xlinkNS = "http://www.w3.org/1999/xlink"
	maxSide = 10000
)

// The page-image allow-list, the same as drum-charts' scripts/site-data.py
// (design, Page images).
var (
	svgElements   = []string{"svg", "defs", "g", "path", "use", "rect", "clipPath"}
	svgAttributes = []string{
		"xmlns", "xmlns:xlink", "version", "width", "height", "viewBox", "id",
		"d", "x", "y", "transform", "fill", "fill-opacity", "fill-rule",
		"stroke", "stroke-width", "stroke-linecap", "stroke-linejoin",
		"stroke-miterlimit", "stroke-opacity", "stroke-dasharray",
		"stroke-dashoffset", "opacity", "clip-path", "clip-rule", "href",
		"xlink:href",
	}
	hrefRe    = regexp.MustCompile(`^#[A-Za-z0-9_.:-]+$`)
	urlRe     = regexp.MustCompile(`^url\(#[A-Za-z0-9_.:-]+\)$`)
	viewBoxRe = regexp.MustCompile(`^0 0 ([0-9]+(\.[0-9]+)?) ([0-9]+(\.[0-9]+)?)$`)
)

// CheckSVG holds a page image to the allow-list and returns the width and
// height of its viewBox, rounded for the <img> attributes. encoding/xml in
// strict mode expands only the five predefined entities, so nothing external
// is ever loaded.
func CheckSVG(b []byte) (width, height int, err error) {
	dec := xml.NewDecoder(bytes.NewReader(b)) //nolint:gosec // G709: checking untrusted XML is the point; tokens only, no unmarshalling
	dec.Strict = true
	depth, roots := 0, 0
	for {
		tok, err := dec.Token()
		if errors.Is(err, io.EOF) {
			break
		}
		if err != nil {
			return 0, 0, fmt.Errorf("not well-formed XML: %w", err)
		}
		switch t := tok.(type) {
		case xml.StartElement:
			if t.Name.Space != svgNS || !slices.Contains(svgElements, t.Name.Local) {
				return 0, 0, fmt.Errorf("element %s not allowed", qualified(t.Name))
			}
			if depth == 0 {
				roots++
				if roots > 1 || t.Name.Local != "svg" {
					return 0, 0, errors.New("the root must be one <svg>")
				}
				if width, height, err = viewBox(t.Attr); err != nil {
					return 0, 0, err
				}
			}
			for _, a := range t.Attr {
				if err := checkAttr(a); err != nil {
					return 0, 0, fmt.Errorf("<%s>: %w", t.Name.Local, err)
				}
			}
			depth++
		case xml.EndElement:
			depth--
		case xml.CharData:
			if len(bytes.Trim(t, " \t\r\n")) > 0 {
				return 0, 0, errors.New("character data not allowed")
			}
		case xml.ProcInst:
			if t.Target != "xml" {
				return 0, 0, fmt.Errorf("processing instruction <?%s not allowed", t.Target)
			}
		case xml.Directive:
			return 0, 0, errors.New("<!DOCTYPE> or another directive not allowed")
		}
	}
	if roots == 0 {
		return 0, 0, errors.New("no <svg> element")
	}
	return width, height, nil
}

// qualified names an element or attribute the way the allow-list writes it.
func qualified(n xml.Name) string {
	switch n.Space {
	case "", svgNS:
		return n.Local
	case xlinkNS:
		return "xlink:" + n.Local
	}
	return n.Space + ":" + n.Local
}

func checkAttr(a xml.Attr) error {
	name := qualified(a.Name)
	if !slices.Contains(svgAttributes, name) {
		return fmt.Errorf("attribute %s not allowed", name)
	}
	v := a.Value
	if name == "href" || name == "xlink:href" {
		if !hrefRe.MatchString(v) {
			return fmt.Errorf("%s=%q is not a reference inside the image", name, v)
		}
		return nil
	}
	// CSS function names are case-insensitive and take escapes.
	if strings.Contains(v, `\`) || (strings.Contains(strings.ToLower(v), "url(") && !urlRe.MatchString(v)) {
		return fmt.Errorf("%s=%q not allowed", name, v)
	}
	return nil
}

func viewBox(attrs []xml.Attr) (width, height int, err error) {
	for _, a := range attrs {
		if a.Name.Space != "" || a.Name.Local != "viewBox" {
			continue
		}
		m := viewBoxRe.FindStringSubmatch(a.Value)
		if m == nil {
			break
		}
		w, errW := strconv.ParseFloat(m[1], 64)
		h, errH := strconv.ParseFloat(m[3], 64)
		if errW != nil || errH != nil || w <= 0 || h <= 0 || w > maxSide || h > maxSide {
			break
		}
		return int(math.Round(w)), int(math.Round(h)), nil
	}
	return 0, 0, fmt.Errorf("the root <svg> needs a viewBox of \"0 0 <w> <h>\", each above 0 and at most %d", maxSide)
}
