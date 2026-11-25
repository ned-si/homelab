#!/usr/bin/env python3
"""site_markup.py <public dir> [host] -- markup check of the built site.
site_markup.py --css <file>... -- no colour literal in the site stylesheets.

Fails on <form>, <iframe>, <style>, style= and on* attributes, an inline
<script>, a <script src> other than /stats/s.js, and a src= or href= outside
<article> to an origin other than the SITE_HOSTS (the canonical <link> and
an <a> to one of the LINKS or to ACCOUNT excepted). The CSP of the site
would block most of these; this catches them before the browser does.

Every page also needs the site navigation, the same markup everywhere
(public-website design, Shared layout): one <nav class="site"
aria-label="Site"> inside <header class="site">, holding only <a> elements
with href and nothing else but aria-current, the NAV links in order, at most
one of them aria-current="page", and that one on the page itself or on a
parent path of it. A page whose own URL is in NAV marks it.

On the THEMED hosts every page also carries the preferences
(site-theme-language design, Markup): one <p class="prefs"> in <header
class="site"> after the nav, the sun (a.to-light) then the moon (a.to-dark),
each to /set-theme/<theme><path> with rel="nofollow", its title, an
aria-hidden SVG icon and its visually hidden name; <path> is the page's own
path, or / on a 404 page. /theme.css is the last stylesheet.

Text: no page says "(I checked)", the landing page and the About page
never mention watches or photography, the landing page has no "Start
here" and no "no cookies", and the About page's certification years are
newest first.

--css: the palette files (theme-*.css) are the only place a colour is
written; the other stylesheets hold no #hex, rgb(), hsl() or named colour.
"""
import pathlib
import re
import sys
from html.parser import HTMLParser
from urllib.parse import urljoin, urlsplit

STATS_SCRIPT = "/stats/s.js"
REPO = "https://github.com/ned-si/homelab/"
# The <a> targets allowed outside <article>: the ci runs' pull requests, the
# source of the dashboard's DORA bands, the SLSA levels and the tech radar's
# model.
LINKS = (REPO, "https://dora.dev/", "https://slsa.dev/", "https://github.com/zalando/tech-radar")
# The operator's GitHub account, the landing page's overview link. Exact,
# so links to other repositories stay inside <article>.
ACCOUNT = "https://github.com/ned-si/"
ABOUT = "https://blog.nedsi.io/about/"
EVERYWHERE = ("(i checked)",)
# Home and About never mention watches or photography (operator, 2026-11-24).
BANNED = {
    "https://nedsi.io/": EVERYWHERE + ("watch", "photograph", "start here", "no cookies"),
    ABOUT: EVERYWHERE + ("watch", "photograph"),
}
SITE_HOSTS = ("nedsi.io", "blog.nedsi.io", "homelab.nedsi.io", "techradar.nedsi.io")
# The hosts whose pages carry the theme toggle (site-theme-language tasks 1-3).
THEMED = ("nedsi.io", "blog.nedsi.io", "homelab.nedsi.io")
PREFS = [
    ("to-light", "light", "Light theme, remembered with a cookie", "Light theme"),
    ("to-dark", "dark", "Dark theme", "Dark theme"),
]
NAV = [
    ("Home", "https://nedsi.io/"),
    ("Blog", "https://blog.nedsi.io/"),
    ("Homelab", "https://homelab.nedsi.io/"),
    ("About", "https://blog.nedsi.io/about/"),
]


class Checker(HTMLParser):
    def __init__(self, host, url):
        super().__init__(convert_charrefs=True)
        self.host = host
        self.url = url
        self.article = 0
        self.navs = 0
        self.in_nav = False
        self.in_header = False
        self.link = None
        self.links = []
        self.problems = []
        self.text = []
        self.heading = None
        self.section = ""
        self.item = None
        self.years = []
        self.prefs = 0
        self.in_prefs = False
        self.pref = None
        self.pref_links = []
        self.vh = False
        self.stylesheets = []

    def bad(self, msg):
        self.problems.append((self.getpos()[0], msg))

    def foreign(self, url, allowed):
        parts = urlsplit(url.strip())
        return bool(parts.netloc) and parts.hostname not in allowed

    def handle_starttag(self, tag, attrs):
        a = dict(attrs)
        if tag == "article":
            self.article += 1
        if tag == "header" and "site" in (a.get("class") or "").split():
            self.in_header = True
        if tag == "nav" and "site" in (a.get("class") or "").split():
            self.navs += 1
            self.in_nav = True
            if not self.in_header:
                self.bad('<nav class="site"> outside <header class="site">')
            if a != {"class": "site", "aria-label": "Site"}:
                self.bad(f'<nav class="site"> attributes {a}, want class="site" aria-label="Site"')
        elif self.in_nav and tag != "a":
            self.bad(f'<{tag}> in <nav class="site">, want only <a>')
        if tag == "p" and self.in_header and "prefs" in (a.get("class") or "").split():
            self.prefs += 1
            self.in_prefs = True
            if self.navs == 0 or self.in_nav:
                self.bad('<p class="prefs"> before the end of <nav class="site">')
        if self.in_prefs:
            if tag == "a":
                self.pref = {k: a.get(k) for k in ("class", "href", "rel", "title")}
                self.pref.update(text="", icon=False)
            elif tag == "svg" and self.pref is not None:
                self.pref["icon"] = a.get("aria-hidden") == "true" and "icon" in (a.get("class") or "").split()
            elif tag == "span" and "vh" in (a.get("class") or "").split():
                self.vh = True
        if tag == "link" and "stylesheet" in (a.get("rel") or "").split():
            self.stylesheets.append(a.get("href"))
        if tag == "a" and self.in_nav:
            href = urljoin(self.url, a.get("href") or "")
            self.link = [href, "", a.get("aria-current") == "page"]
            extra = sorted(set(a) - {"href", "aria-current"})
            if extra:
                self.bad(f'<a> in <nav class="site"> with {extra}, want only href and aria-current')
        if re.fullmatch(r"h[1-6]", tag):
            self.heading = ""
        if tag == "li" and self.section == "Certifications":
            self.item = ""
        if tag in ("form", "iframe", "style"):
            self.bad(f"<{tag}>")
        for name in a:
            if name == "style" or name.startswith("on"):
                self.bad(f"{name}= on <{tag}>")
        if tag == "script":
            src = a.get("src")
            if not src:
                self.bad("inline <script>")
            elif self.foreign(src, (self.host,)) or urlsplit(src).path != STATS_SCRIPT:
                self.bad(f"<script src={src}>")
        if self.article:
            return
        canonical = tag == "link" and "canonical" in (a.get("rel") or "").split()
        for name in ("src", "href"):
            url = a.get(name)
            link = tag == "a" and name == "href" and ((url or "").startswith(LINKS) or url == ACCOUNT)
            if url and self.foreign(url, SITE_HOSTS) and not canonical and not link:
                self.bad(f"{name}={url} outside <article>")

    def handle_data(self, data):
        self.text.append(data)
        if self.vh and self.pref is not None:
            self.pref["text"] += data
        if self.link is not None:
            self.link[1] += data
        if self.heading is not None:
            self.heading += data
        if self.item is not None:
            self.item += data

    def handle_endtag(self, tag):
        if tag == "article" and self.article:
            self.article -= 1
        if tag == "a" and self.link is not None:
            self.links.append((self.link[1].strip(), self.link[0], self.link[2]))
            self.link = None
        if tag == "nav":
            self.in_nav = False
        if tag == "span":
            self.vh = False
        if tag == "a" and self.pref is not None:
            self.pref_links.append(self.pref)
            self.pref = None
        # A minified page can omit </p> before </header>.
        if tag in ("p", "header"):
            self.in_prefs = False
        if tag == "header":
            self.in_header = False
        if re.fullmatch(r"h[1-6]", tag) and self.heading is not None:
            self.section = self.heading.strip()
            self.heading = None
        if tag == "li" and self.item is not None:
            year = re.match(r"\s*(\d{4})\b", self.item)
            if year:
                self.years.append(int(year.group(1)))
            self.item = None

    def check_text(self):
        text = " ".join(" ".join(self.text).lower().split())
        for word in BANNED.get(self.url, EVERYWHERE):
            if word in text:
                self.problems.append((0, f'says "{word}"'))
        if self.url != ABOUT:
            return
        if not self.years:
            self.problems.append((0, "no certification years under Certifications"))
        elif any(a <= b for a, b in zip(self.years, self.years[1:])):
            self.problems.append((0, f"certification years {self.years}, want newest first"))

    def check_nav(self):
        if self.navs != 1:
            self.problems.append((0, f'{self.navs} <nav class="site">, want 1'))
            return
        nav = NAV
        got = [(text, href) for text, href, _ in self.links]
        if got != nav:
            self.problems.append((0, f"site nav {got}, want {nav}"))
            return
        current = [href for _, href, cur in self.links if cur]
        if len(current) > 1:
            self.problems.append((0, f"aria-current on {current}, want at most one"))
        elif current and not self.url.startswith(current[0]):
            self.problems.append((0, f"aria-current on {current[0]}, not this page or a parent"))
        elif not current and self.url in dict(nav).values():
            self.problems.append((0, "no aria-current on the link to this page"))


    def check_prefs(self):
        if self.host not in THEMED:
            return
        if self.prefs != 1:
            self.problems.append((0, f'{self.prefs} <p class="prefs"> in <header class="site">, want 1'))
            return
        path = urlsplit(self.url).path
        if self.host == "homelab.nedsi.io" or path.rsplit("/", 1)[-1] == "404.html":
            path = "/"
        want = [
            {"class": cls, "href": f"/set-theme/{theme}{path}", "rel": "nofollow", "title": title, "text": name, "icon": True}
            for cls, theme, title, name in PREFS
        ]
        got = [{**link, "text": link["text"].strip()} for link in self.pref_links]
        if got != want:
            self.problems.append((0, f"preferences {got}, want {want}"))
        if not self.stylesheets or self.stylesheets[-1] != "/theme.css":
            self.problems.append((0, f"stylesheets {self.stylesheets}, want /theme.css last"))


# The CSS named colours (CSS Color 4), and the hex, rgb() and hsl() forms.
NAMED = set("""aliceblue antiquewhite aqua aquamarine azure beige bisque black blanchedalmond blue
blueviolet brown burlywood cadetblue chartreuse chocolate coral cornflowerblue cornsilk crimson
cyan darkblue darkcyan darkgoldenrod darkgray darkgreen darkgrey darkkhaki darkmagenta
darkolivegreen darkorange darkorchid darkred darksalmon darkseagreen darkslateblue darkslategray
darkslategrey darkturquoise darkviolet deeppink deepskyblue dimgray dimgrey dodgerblue firebrick
floralwhite forestgreen fuchsia gainsboro ghostwhite gold goldenrod gray green greenyellow grey
honeydew hotpink indianred indigo ivory khaki lavender lavenderblush lawngreen lemonchiffon
lightblue lightcoral lightcyan lightgoldenrodyellow lightgray lightgreen lightgrey lightpink
lightsalmon lightseagreen lightskyblue lightslategray lightslategrey lightsteelblue lightyellow
lime limegreen linen magenta maroon mediumaquamarine mediumblue mediumorchid mediumpurple
mediumseagreen mediumslateblue mediumspringgreen mediumturquoise mediumvioletred midnightblue
mintcream mistyrose moccasin navajowhite navy oldlace olive olivedrab orange orangered orchid
palegoldenrod palegreen paleturquoise palevioletred papayawhip peachpuff peru pink plum
powderblue purple rebeccapurple red rosybrown royalblue saddlebrown salmon sandybrown seagreen
seashell sienna silver skyblue slateblue slategray slategrey snow springgreen steelblue tan teal
thistle tomato turquoise violet wheat white whitesmoke yellow yellowgreen""".split())
LITERAL = re.compile(r"#[0-9a-fA-F]{3,8}\b|\b(?:rgba?|hsla?|hwb|lab|lch|oklab|oklch)\(")


def colour_literals(css):
    """The colour literals in the declaration values of css, by line."""
    css = re.sub(r"/\*.*?\*/", lambda m: re.sub(r"[^\n]", " ", m.group()), css, flags=re.S)
    found = []
    for m in re.finditer(r"(?<=[:])([^;{}]*)", css):
        value = re.sub(r"var\(--[a-z0-9-]+\)", "", m.group(1))
        line = css.count("\n", 0, m.start()) + 1
        if LITERAL.search(value):
            found.append((line, value.strip()))
        else:
            words = {w.lower() for w in re.findall(r"[A-Za-z]+", value)}
            if words & NAMED:
                found.append((line, value.strip()))
    return found


def check_css(files):
    failed = False
    for name in files:
        path = pathlib.Path(name)
        for line, value in colour_literals(path.read_text(encoding="utf-8")):
            print(f"{path}:{line}: colour literal '{value}'; colours live in theme-*.css")
            failed = True
    print(f"site_markup: {len(files)} stylesheets checked for colour literals")
    sys.exit(1 if failed else 0)


def page_url(host, rel):
    path = "/" + rel.as_posix()
    if path.endswith("/index.html"):
        path = path[: -len("index.html")]
    return f"https://{host}{path}"


def main():
    if len(sys.argv) > 2 and sys.argv[1] == "--css":
        check_css(sys.argv[2:])
    if len(sys.argv) not in (2, 3):
        sys.exit(__doc__)
    public = pathlib.Path(sys.argv[1])
    host = sys.argv[2] if len(sys.argv) == 3 else "blog.nedsi.io"
    pages = sorted(public.rglob("*.html"))
    if not pages:
        sys.exit(f"site_markup: no HTML under {public}")
    failed = False
    for page in pages:
        rel = page.relative_to(public)
        checker = Checker(host, page_url(host, rel))
        checker.feed(page.read_text(encoding="utf-8"))
        checker.close()
        checker.check_nav()
        checker.check_prefs()
        checker.check_text()
        for line, msg in checker.problems:
            print(f"{rel}:{line}: {msg}")
            failed = True
    print(f"site_markup: {len(pages)} pages checked")
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
