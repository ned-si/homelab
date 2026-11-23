"""scripts/ci/site_markup.py: the markup and navigation checks."""
import subprocess
import sys

import pytest

from conftest import REPO, SCRIPTS

CHECK = str(SCRIPTS / "site_markup.py")


def nav(current=None, links=None):
    links = links or [
        ("Home", "https://nedsi.io/"),
        ("Blog", "/"),
        ("Homelab", "https://homelab.nedsi.io/"),
        ("About", "/about/"),
    ]
    out = []
    for text, href in links:
        cur = ' aria-current="page"' if text == current else ""
        out.append(f'<a href="{href}"{cur}>{text}</a>')
    return '<nav class="site" aria-label="Site">' + "".join(out) + "</nav>"


def run(tmp_path, pages, host=None):
    for rel, body in pages.items():
        path = tmp_path / rel
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(f"<!doctype html><html><body>{body}</body></html>", encoding="utf-8")
    args = [sys.executable, CHECK, str(tmp_path)] + ([host] if host else [])
    return subprocess.run(args, capture_output=True, text=True)


@pytest.mark.parametrize(
    "pages",
    [
        {"index.html": nav("Blog")},
        {"posts/x/index.html": nav("Blog"), "tags/index.html": nav("Blog")},
        {"about/index.html": nav("About"), "privacy/index.html": nav(), "404.html": nav()},
    ],
)
def test_blog_pages_pass(tmp_path, pages):
    res = run(tmp_path, pages)
    assert res.returncode == 0, res.stdout


@pytest.mark.parametrize(
    "body, msg",
    [
        ("<p>no nav</p>", '0 <nav class="site">'),
        (nav("Blog") + nav("Blog"), '2 <nav class="site">'),
        (nav("Blog", [("Blog", "/"), ("Home", "https://nedsi.io/")]), "site nav"),
        (nav(), "no aria-current"),
        (nav("About"), "not this page or a parent"),
        (nav("Blog").replace("<a", '<a aria-current="page"', 1), "at most one"),
        (nav("Blog") + '<a href="https://example.org/">x</a>', "outside <article>"),
    ],
)
def test_blog_home_fails(tmp_path, body, msg):
    res = run(tmp_path, {"index.html": body})
    assert res.returncode == 1
    assert msg in res.stdout


def test_sibling_site_links_allowed_outside_article(tmp_path):
    body = nav("Blog") + '<footer><a href="https://nedsi.io/">x</a></footer>'
    assert run(tmp_path, {"index.html": body}).returncode == 0


DASHBOARD_GOLDEN = sorted((REPO / "dashboard/internal/web/testdata").glob("*.golden.html"))


@pytest.mark.parametrize("page", DASHBOARD_GOLDEN, ids=lambda p: p.name)
def test_dashboard_golden_pages_pass(page):
    """The app's pages carry the site navigation for their host and the same markup rules."""
    import site_markup

    checker = site_markup.Checker("homelab.nedsi.io", "https://homelab.nedsi.io/")
    checker.feed(page.read_text(encoding="utf-8"))
    checker.close()
    checker.check_nav()
    assert checker.problems == []


def test_dashboard_golden_pages_exist():
    assert {p.name for p in DASHBOARD_GOLDEN} >= {
        "full.golden.html",
        "since.golden.html",
        "exhausted.golden.html",
        "empty.golden.html",
        "notfound.golden.html",
    }


def test_landing_page_passes():
    res = subprocess.run(
        [sys.executable, CHECK, str(REPO / "apps/website/landing"), "nedsi.io"],
        capture_output=True,
        text=True,
    )
    assert res.returncode == 0, res.stdout
