#!/usr/bin/env python3
"""site_contrast.py [dir] -- WCAG 2.2 contrast of both palettes.

Reads theme-dark.css and theme-light.css (default site/assets/css/) and, in
each theme, checks every pair of PAIRS (.kiro/specs/site-theme-language/
design.md#contrast). Fails on a pair under its minimum, on a property used in
a pair but missing from a file, on a property in a file but in no pair,
when the two files do not define the same properties, and when a file holds
anything but custom properties, its color-scheme and the rule that hides the
link to its own theme (Requirement 1.6).
"""
import pathlib
import re
import sys

SYN = [f"syn-{n}" for n in (
    "comment", "keyword", "string", "number", "operator", "constant",
    "function", "variable", "label", "deleted", "inserted", "error",
)]
RINGS = ["ring-adopt", "ring-trial", "ring-assess", "ring-hold"]
STATUS = ["ok", "warn", "bad", "none"]
TEXT = ["fg", "muted", "link"]

# (foregrounds, backgrounds, minimum, WCAG criterion)
PAIRS = [
    (TEXT, ["bg", "panel", "tile", "code-bg"], 4.5, "1.4.3"),
    (STATUS, ["bg", "panel", "tile"], 4.5, "1.4.3"),
    (["fg", "muted"] + SYN, ["code-bg", "rule"], 4.5, "1.4.3"),
    (["blip-text"], RINGS, 4.5, "1.4.3"),
    # The ring names are text, the blips and ring lines graphics.
    (RINGS, ["bg"], 4.5, "1.4.3"),
    (["radar-line"], ["bg"], 3, "1.4.11"),
    (STATUS, ["panel", "tile"], 3, "1.4.11"),
    (["link"], ["bg", "panel", "tile"], 3, "1.4.11"),
    (["fg"], ["bg"], 3, "1.4.11"),
]

PROP = re.compile(r"--([a-z0-9-]+)\s*:\s*(#[0-9a-fA-F]{6})\s*;")


def luminance(hex_colour):
    total = 0.0
    for i, weight in enumerate((0.2126, 0.7152, 0.0722)):
        s = int(hex_colour[1 + 2 * i:3 + 2 * i], 16) / 255
        s = s / 12.92 if s <= 0.04045 else ((s + 0.055) / 1.055) ** 2.4
        total += weight * s
    return total


def ratio(a, b):
    la, lb = luminance(a), luminance(b)
    return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)


def shape(theme, text):
    """Requirement 1.6: the problems with the file's rules, if any."""
    text = re.sub(r"/\*.*?\*/", "", text, flags=re.S)
    m = re.fullmatch(r"\s*:root\s*\{([^}]*)\}\s*\.prefs \.to-(dark|light)\s*\{\s*display:\s*none;?\s*\}\s*", text)
    if not m:
        return [f"theme-{theme}.css: want only :root {{ ... }} and .prefs .to-{theme} {{ display: none; }}"]
    problems = []
    if m.group(2) != theme:
        problems.append(f"theme-{theme}.css hides .to-{m.group(2)}, want .to-{theme}")
    for decl in filter(None, (d.strip() for d in m.group(1).split(";"))):
        if decl != f"color-scheme: {theme}" and not PROP.fullmatch(decl + ";"):
            problems.append(f"theme-{theme}.css: '{decl}' is not a colour property or color-scheme: {theme}")
    return problems


def palette(path):
    return {m.group(1): m.group(2).lower() for m in PROP.finditer(path.read_text(encoding="utf-8"))}


def check(themes):
    problems = []
    used = {name for fgs, bgs, _, _ in PAIRS for name in fgs + bgs}
    names = [set(colours) for colours in themes.values()]
    if names and any(n != names[0] for n in names):
        problems.append(f"the palettes define different properties: {sorted(set.union(*names) - set.intersection(*names))}")
    for theme, colours in themes.items():
        for name in sorted(used - set(colours)):
            problems.append(f"{theme}: no --{name}")
        for name in sorted(set(colours) - used):
            problems.append(f"{theme}: --{name} is in no contrast pair; add its row to PAIRS")
        for fgs, bgs, minimum, wcag in PAIRS:
            for fg in fgs:
                for bg in bgs:
                    if fg not in colours or bg not in colours:
                        continue
                    r = ratio(colours[fg], colours[bg])
                    if r < minimum:
                        problems.append(
                            f"{theme}: --{fg} {colours[fg]} on --{bg} {colours[bg]}: "
                            f"{r:.2f}, want at least {minimum} (WCAG {wcag})"
                        )
    return problems


def main():
    if len(sys.argv) > 2:
        sys.exit(__doc__)
    root = pathlib.Path(sys.argv[1] if len(sys.argv) == 2 else "site/assets/css")
    themes, problems = {}, []
    for theme in ("dark", "light"):
        path = root / f"theme-{theme}.css"
        if not path.is_file():
            sys.exit(f"site_contrast: no {path}")
        themes[theme] = palette(path)
        problems += shape(theme, path.read_text(encoding="utf-8"))
    problems += check(themes)
    for p in problems:
        print(f"site_contrast: FAIL {p}")
    if not problems:
        print(f"site_contrast: {sum(len(f) * len(b) for f, b, _, _ in PAIRS)} pairs pass in each theme")
    sys.exit(1 if problems else 0)


if __name__ == "__main__":
    main()
