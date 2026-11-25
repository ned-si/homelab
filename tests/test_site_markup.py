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
        ("Tech radar", "https://techradar.nedsi.io/"),
        ("About", "/about/"),
    ]
    out = []
    for text, href in links:
        cur = ' aria-current="page"' if text == current else ""
        out.append(f'<a href="{href}"{cur}>{text}</a>')
    return '<header class="site"><nav class="site" aria-label="Site">' + "".join(out) + "</nav></header>"


def prefs(path="/"):
    """The preferences of a page at path, as the layouts render them."""
    icon = '<svg class="icon" viewBox="0 0 24 24" aria-hidden="true"><path d="M1 1"/></svg>'
    return (
        '<p class="prefs">'
        f'<a class="to-light" href="/set-theme/light{path}" rel="nofollow" title="Light theme, remembered with a cookie">'
        f'{icon}<span class="vh">Light theme</span></a>'
        f'<a class="to-dark" href="/set-theme/dark{path}" rel="nofollow" title="Dark theme">'
        f'{icon}<span class="vh">Dark theme</span></a></p>'
    )


def page_path(rel):
    if rel.endswith("404.html"):
        return "/"
    return "/" + rel[: -len("index.html")] if rel.endswith("index.html") else "/" + rel


CERTS = "<h3>Certifications</h3><ul><li>2024: KCNA</li><li>2023: CISSP</li><li>2019: Security+</li></ul>"


def run(tmp_path, pages, host=None):
    for rel, body in pages.items():
        path = tmp_path / rel
        path.parent.mkdir(parents=True, exist_ok=True)
        body = body.replace("</nav></header>", "</nav>" + prefs(page_path(rel)) + "</header>")
        head = '<head><link rel="stylesheet" href="/theme.css"></head>'
        path.write_text(f"<!doctype html><html>{head}<body>{body}</body></html>", encoding="utf-8")
    args = [sys.executable, CHECK, str(tmp_path)] + ([host] if host else [])
    return subprocess.run(args, capture_output=True, text=True)


@pytest.mark.parametrize(
    "pages",
    [
        {"index.html": nav("Blog")},
        {"posts/x/index.html": nav("Blog"), "tags/index.html": nav("Blog")},
        {"about/index.html": nav("About") + CERTS, "privacy/index.html": nav(), "404.html": nav()},
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
        (nav("Blog").replace('<header class="site">', "<header>"), "outside <header"),
        (nav("Blog").replace('<nav class="site"', '<nav class="site wide"'), "attributes"),
        (nav("Blog").replace("</a>", "</a><span>|</span>", 1), "want only <a>"),
        (nav("Blog").replace("<a ", '<a class="x" ', 1), "want only href and aria-current"),
        (nav("Blog", [("Blog", "/"), ("Home", "https://nedsi.io/")]), "site nav"),
        (nav(), "no aria-current"),
        (nav("About"), "not this page or a parent"),
        (nav("Blog").replace("<a", '<a aria-current="page"', 1), "at most one"),
        (nav("Blog") + '<a href="https://example.org/">x</a>', "outside <article>"),
        (nav("Blog") + '<a href="https://github.com/ned-si/other/">x</a>', "outside <article>"),
        (nav("Blog") + '<img src="https://github.com/ned-si/homelab/x.png">', "outside <article>"),
    ],
)
def test_blog_home_fails(tmp_path, body, msg):
    res = run(tmp_path, {"index.html": body})
    assert res.returncode == 1
    assert msg in res.stdout


def test_sibling_site_links_allowed_outside_article(tmp_path):
    body = nav("Blog") + '<footer><a href="https://nedsi.io/">x</a></footer>'
    assert run(tmp_path, {"index.html": body}).returncode == 0


def test_repository_links_allowed_outside_article(tmp_path):
    body = nav("Blog") + '<a href="https://github.com/ned-si/homelab/pull/1">#1</a>'
    assert run(tmp_path, {"index.html": body}).returncode == 0


def test_dora_links_allowed_outside_article(tmp_path):
    body = nav("Blog") + '<a href="https://dora.dev/research/2023/dora-report/">x</a>'
    assert run(tmp_path, {"index.html": body}).returncode == 0
    body = nav("Blog") + '<img src="https://dora.dev/x.png">'
    assert run(tmp_path, {"index.html": body}).returncode == 1


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


@pytest.mark.parametrize(
    "rel, host, body, msg",
    [
        ("index.html", "nedsi.io", "<p>Start\nhere</p>", 'says "start here"'),
        ("index.html", "nedsi.io", "<p>Luxury Watches</p>", 'says "watch"'),
        ("index.html", "nedsi.io", "<p>a photographer</p>", 'says "photograph"'),
        ("about/index.html", None, CERTS + "<p>watch industry</p>", 'says "watch"'),
        ("posts/x/index.html", None, "<p>No tracking (I checked).</p>", 'says "(i checked)"'),
        ("about/index.html", None, "<p>no list</p>", "no certification years"),
        (
            "about/index.html",
            None,
            "<h3>Certifications</h3><ul><li>2019: Security+</li><li>2024: KCNA</li></ul>",
            "want newest first",
        ),
        (
            "about/index.html",
            None,
            "<h3>Certifications</h3><ul><li>2024: KCNA</li><li>2024: KCSA</li></ul>",
            "want newest first",
        ),
    ],
)
def test_text_rules_fail(tmp_path, rel, host, body, msg):
    current = {"nedsi.io": "Home", None: "About" if rel.startswith("about") else "Blog"}[host]
    links = None
    if host == "nedsi.io":
        links = [
            ("Home", "/"),
            ("Blog", "https://blog.nedsi.io/"),
            ("Homelab", "https://homelab.nedsi.io/"),
            ("Tech radar", "https://techradar.nedsi.io/"),
            ("About", "https://blog.nedsi.io/about/"),
        ]
    res = run(tmp_path, {rel: nav(current, links) + body}, host)
    assert res.returncode == 1
    assert msg in res.stdout


def test_watch_allowed_on_other_pages(tmp_path):
    assert run(tmp_path, {"posts/x/index.html": nav("Blog") + "<p>watchdog</p>"}).returncode == 0


def test_account_link_allowed_outside_article(tmp_path):
    body = nav("Blog") + '<a href="https://github.com/ned-si/">Projects</a>'
    assert run(tmp_path, {"index.html": body}).returncode == 0


@pytest.mark.parametrize(
    "old, new, msg",
    [
        (prefs("/"), "", '0 <p class="prefs">'),
        (prefs("/"), prefs("/") + prefs("/"), '2 <p class="prefs">'),
        ("/set-theme/light/", "/set-theme/light/about/", "preferences"),
        ('rel="nofollow" title="Dark', 'title="Dark', "preferences"),
        ('<span class="vh">Light theme</span>', "", "preferences"),
        ('aria-hidden="true"', "", "preferences"),
        ('href="/theme.css"', 'href="/other.css"', "want /theme.css last"),
    ],
)
def test_prefs_fail(tmp_path, old, new, msg):
    page = (
        '<!doctype html><html><head><link rel="stylesheet" href="/theme.css"></head><body>'
        + nav("Blog").replace("</nav></header>", "</nav>" + prefs("/") + "</header>")
        + "</body></html>"
    )
    (tmp_path / "index.html").write_text(page.replace(old, new, 1), encoding="utf-8")
    res = subprocess.run([sys.executable, CHECK, str(tmp_path)], capture_output=True, text=True)
    assert res.returncode == 1
    assert msg in res.stdout


def test_prefs_paths(tmp_path):
    pages = {"about/index.html": nav("About") + CERTS, "404.html": nav(), "posts/x/index.html": nav("Blog")}
    assert run(tmp_path, pages).returncode == 0


def test_prefs_minified_without_end_p(tmp_path):
    body = nav("Blog").replace("</nav></header>", "</nav>" + prefs("/").replace("</p>", "") + "</header>")
    assert run(tmp_path, {"index.html": body}).returncode == 0


def test_landing_no_cookies_line(tmp_path):
    links = [
        ("Home", "/"),
        ("Blog", "https://blog.nedsi.io/"),
        ("Homelab", "https://homelab.nedsi.io/"),
        ("Tech radar", "https://techradar.nedsi.io/"),
        ("About", "https://blog.nedsi.io/about/"),
    ]
    res = run(tmp_path, {"index.html": nav("Home", links) + "<p>No cookies.</p>"}, "nedsi.io")
    assert res.returncode == 1
    assert 'says "no cookies"' in res.stdout


@pytest.mark.parametrize(
    "css, ok",
    [
        ("body { color: var(--fg); background: var(--bg); }", True),
        ("/* #fff in a comment */ a:hover { color: currentColor; }", True),
        (".x { border: 1px solid transparent; }", True),
        ("body { color: #fff; }", False),
        ("body { color: rgb(0 0 0); }", False),
        ("body { background: hsl(0 0% 0%); }", False),
        ("body { color: White; }", False),
        (".x { border: 1px solid var(--rule, red); }", False),
    ],
)
def test_colour_literals(tmp_path, css, ok):
    f = tmp_path / "x.css"
    f.write_text(css, encoding="utf-8")
    res = subprocess.run([sys.executable, CHECK, "--css", str(f)], capture_output=True, text=True)
    assert (res.returncode == 0) is ok, res.stdout
