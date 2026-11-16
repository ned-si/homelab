#!/usr/bin/env python3
"""site_markup.py <public dir> [host] -- markup check of the built site.

Fails on <form>, <iframe>, <style>, style= and on* attributes, an inline
<script>, a <script src> other than /stats/s.js, and a src= or href= to
another origin outside <article> (the canonical <link> excepted). The CSP of
the site would block most of these; this catches them before the browser does.
"""
import pathlib
import sys
from html.parser import HTMLParser
from urllib.parse import urlsplit

STATS_SCRIPT = "/stats/s.js"


class Checker(HTMLParser):
    def __init__(self, host):
        super().__init__(convert_charrefs=True)
        self.host = host
        self.article = 0
        self.problems = []

    def bad(self, msg):
        self.problems.append((self.getpos()[0], msg))

    def foreign(self, url):
        parts = urlsplit(url.strip())
        return bool(parts.netloc) and parts.hostname != self.host

    def handle_starttag(self, tag, attrs):
        a = dict(attrs)
        if tag == "article":
            self.article += 1
        if tag in ("form", "iframe", "style"):
            self.bad(f"<{tag}>")
        for name in a:
            if name == "style" or name.startswith("on"):
                self.bad(f"{name}= on <{tag}>")
        if tag == "script":
            src = a.get("src")
            if not src:
                self.bad("inline <script>")
            elif self.foreign(src) or urlsplit(src).path != STATS_SCRIPT:
                self.bad(f"<script src={src}>")
        if self.article:
            return
        canonical = tag == "link" and "canonical" in (a.get("rel") or "").split()
        for name in ("src", "href"):
            url = a.get(name)
            if url and self.foreign(url) and not canonical:
                self.bad(f"{name}={url} outside <article>")

    def handle_endtag(self, tag):
        if tag == "article" and self.article:
            self.article -= 1


def main():
    if len(sys.argv) not in (2, 3):
        sys.exit(__doc__)
    public = pathlib.Path(sys.argv[1])
    host = sys.argv[2] if len(sys.argv) == 3 else "nedsi.io"
    pages = sorted(public.rglob("*.html"))
    if not pages:
        sys.exit(f"site_markup: no HTML under {public}")
    failed = False
    for page in pages:
        checker = Checker(host)
        checker.feed(page.read_text(encoding="utf-8"))
        checker.close()
        for line, msg in checker.problems:
            print(f"{page.relative_to(public)}:{line}: {msg}")
            failed = True
    print(f"site_markup: {len(pages)} pages checked")
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
