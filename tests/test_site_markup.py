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


def toggle(lang, other_url):
    """The language toggle of a page in lang whose other version is other_url."""
    if lang == "fr":
        return f'<a class="lang" href="{other_url}" hreflang="en" lang="en-GB" aria-label="English">EN</a>'
    return f'<a class="lang" href="{other_url}" hreflang="fr" lang="fr-CH" aria-label="Français">FR</a>'


def prefs(path="/", lang_toggle=""):
    """The preferences of a page at path, as the layouts render them."""
    icon = '<svg class="icon" viewBox="0 0 24 24" aria-hidden="true"><path d="M1 1"/></svg>'
    fr = path.startswith("/fr/")
    light = ("Thème clair, mémorisé dans un cookie", "Thème clair") if fr else ("Light theme, remembered with a cookie", "Light theme")
    dark = "Thème sombre" if fr else "Dark theme"
    return (
        '<p class="prefs">' + lang_toggle
        + f'<a class="to-light" href="/set-theme/light{path}" rel="nofollow" title="{light[0]}">'
        f'{icon}<span class="vh">{light[1]}</span></a>'
        f'<a class="to-dark" href="/set-theme/dark{path}" rel="nofollow" title="{dark}">'
        f'{icon}<span class="vh">{dark}</span></a></p>'
    )


def page_path(rel):
    if rel.endswith("404.html"):
        return "/fr/" if rel.startswith("fr/") else "/"
    return "/" + rel[: -len("index.html")] if rel.endswith("index.html") else "/" + rel


def head(host, rel):
    """<html> and <head> of a page: lang, canonical, hreflang, the stylesheet."""
    path = page_path(rel)
    url = f"https://{host}{path}"
    fr = path.startswith("/fr/")
    en_url = f"https://{host}{path[3:]}" if fr else url
    fr_url = url if fr else f"https://{host}/fr{path}"
    lines = []
    if not rel.endswith("404.html"):
        lines.append(f'<link rel="canonical" href="{url}">')
        lines += [
            f'<link rel="alternate" hreflang="en" href="{en_url}">',
            f'<link rel="alternate" hreflang="fr" href="{fr_url}">',
            f'<link rel="alternate" hreflang="x-default" href="{en_url}">',
        ]
    lines.append('<link rel="stylesheet" href="/theme.css">')
    other = en_url if fr else fr_url
    if rel.endswith("404.html"):
        other = f"https://{host}/" if fr else f"https://{host}/fr/"
    return f'<html lang="{"fr-CH" if fr else "en-GB"}"><head>' + "".join(lines) + "</head>", toggle("fr" if fr else "en", other)


CERTS = "<h3>Certifications</h3><ul><li>2024: KCNA</li><li>2023: CISSP</li><li>2019: Security+</li></ul>"


def page(rel, body, host=None):
    start, lang_toggle = head(host or "blog.nedsi.io", rel)
    body = body.replace("</nav></header>", "</nav>" + prefs(page_path(rel), lang_toggle) + "</header>")
    return f"<!doctype html>{start}<body>{body}</body></html>"


def run(tmp_path, pages, host=None):
    for rel, body in pages.items():
        path = tmp_path / rel
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(page(rel, body, host), encoding="utf-8")
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
    """The app's pages carry the site navigation, the preferences and the
    language links for their language, and the same markup rules."""
    import site_markup

    path = "/fr/" if page.name.startswith("fr-") else "/"
    if page.name.endswith("notfound.golden.html"):
        path += "404.html"
    checker = site_markup.Checker("homelab.nedsi.io", f"https://homelab.nedsi.io{path}")
    checker.feed(page.read_text(encoding="utf-8"))
    checker.close()
    checker.check_nav()
    checker.check_prefs()
    checker.check_language()
    assert checker.problems == []


def test_dashboard_golden_pages_exist():
    assert {p.name for p in DASHBOARD_GOLDEN} >= {
        "full.golden.html",
        "since.golden.html",
        "exhausted.golden.html",
        "empty.golden.html",
        "notfound.golden.html",
        "fr-full.golden.html",
        "fr-notfound.golden.html",
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
        ('<p class="prefs">', '<p class="other">', '0 <p class="prefs">'),
        ("</header>", '<p class="prefs"></p></header>', '2 <p class="prefs">'),
        ("/set-theme/light/", "/set-theme/light/about/", "preferences"),
        ('rel="nofollow" title="Dark', 'title="Dark', "preferences"),
        ('<span class="vh">Light theme</span>', "", "preferences"),
        ('aria-hidden="true"', "", "preferences"),
        ('href="/theme.css"', 'href="/other.css"', "want /theme.css last"),
    ],
)
def test_prefs_fail(tmp_path, old, new, msg):
    html = page("index.html", nav("Blog"))
    (tmp_path / "index.html").write_text(html.replace(old, new, 1), encoding="utf-8")
    res = subprocess.run([sys.executable, CHECK, str(tmp_path)], capture_output=True, text=True)
    assert res.returncode == 1
    assert msg in res.stdout


def test_prefs_paths(tmp_path):
    pages = {"about/index.html": nav("About") + CERTS, "404.html": nav(), "posts/x/index.html": nav("Blog")}
    assert run(tmp_path, pages).returncode == 0


def test_prefs_minified_without_end_p(tmp_path):
    body = nav("Blog").replace("</nav></header>", "</nav>" + prefs("/", toggle("en", "https://blog.nedsi.io/fr/")).replace("</p>", "") + "</header>")
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


FR_NAV = [
    ("Accueil", "https://nedsi.io/fr/"),
    ("Blog", "/fr/"),
    ("Homelab", "https://homelab.nedsi.io/fr/"),
    ("Tech radar", "https://techradar.nedsi.io/fr/"),
    ("À propos", "/fr/about/"),
]


def test_french_pages_pass(tmp_path):
    pages = {
        "fr/index.html": nav("Blog", FR_NAV),
        "fr/about/index.html": nav("À propos", FR_NAV) + CERTS,
        "fr/404.html": nav(None, FR_NAV),
        "index.html": nav("Blog"),
    }
    res = run(tmp_path, pages)
    assert res.returncode == 0, res.stdout


@pytest.mark.parametrize(
    "rel, old, new, msg",
    [
        ("fr/index.html", 'lang="fr-CH"><head>', 'lang="en-GB"><head>', "<html lang=en-GB>, want fr-CH"),
        ("index.html", 'hreflang="x-default"', 'hreflang="de"', "hreflang"),
        ("index.html", '<link rel="alternate" hreflang="fr" href="https://blog.nedsi.io/fr/">', "", "hreflang"),
        ("index.html", 'href="https://blog.nedsi.io/fr/" hreflang="fr"', 'href="/fr/" hreflang="fr"', "language toggle"),
        ("index.html", 'aria-label="Français">FR</a>', 'aria-label="Français">EN</a>', "language toggle"),
        ("index.html", ' aria-label="Français"', "", "language toggle"),
        ("index.html", '<a class="lang"', '<span aria-current="true">EN</span> <a class="lang"', "aria-current in the preferences"),
        ("fr/index.html", '<link rel="canonical" href="https://blog.nedsi.io/fr/">', '<link rel="canonical" href="https://blog.nedsi.io/">', "canonical"),
        ("fr/index.html", "Accueil", "Home", "site nav"),
        ("fr/404.html", '<a class="lang" href="https://blog.nedsi.io/"', '<a class="lang" href="https://blog.nedsi.io/404.html"', "language toggle"),
    ],
)
def test_language_fails(tmp_path, rel, old, new, msg):
    links = None if not rel.startswith("fr/") else FR_NAV
    html = page(rel, nav("Blog" if "404" not in rel else None, links))
    assert old in html
    (tmp_path / rel).parent.mkdir(parents=True, exist_ok=True)
    (tmp_path / rel).write_text(html.replace(old, new, 1), encoding="utf-8")
    res = subprocess.run([sys.executable, CHECK, str(tmp_path)], capture_output=True, text=True)
    assert res.returncode == 1
    assert msg in res.stdout


def test_fallback_page(tmp_path):
    rel = "fr/posts/x/index.html"
    html = page(rel, nav("Blog", FR_NAV) + '<p class="fallback">Cet article</p>')
    html = html.split("<head>")[0] + "<head>" + '<link rel="canonical" href="https://blog.nedsi.io/posts/x/">' + '<link rel="stylesheet" href="/theme.css">' + "</head>" + html.split("</head>")[1]
    (tmp_path / rel).parent.mkdir(parents=True, exist_ok=True)
    (tmp_path / rel).write_text(html, encoding="utf-8")
    res = subprocess.run([sys.executable, CHECK, str(tmp_path)], capture_output=True, text=True)
    assert res.returncode == 0, res.stdout


def test_landing_french_page_passes():
    import site_markup

    assert site_markup.page_url("nedsi.io", __import__("pathlib").PurePosixPath("index-fr.html")) == "https://nedsi.io/fr/"


def write(path, text):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text, encoding="utf-8")


ARTICLE = "---\ntitle: Hello\ndate: 2026-11-20\nsummary: A test.\n---\nBody.\n"
STUB = "---\ntitle: Hello\ndate: 2026-11-20\nsummary: A test.\nfallback: true\n---\n"


@pytest.mark.parametrize(
    "files, msg",
    [
        ({"about/index.md": ARTICLE, "about/index.fr.md": ARTICLE}, None),
        ({"posts/x/index.md": ARTICLE, "posts/x/index.fr.md": STUB}, None),
        ({"posts/x/index.md": ARTICLE}, "no French translation"),
        ({"privacy.md": ARTICLE}, "no French translation"),
        ({"privacy.fr.md": ARTICLE}, "no English original"),
        ({"about/index.md": ARTICLE, "about/index.fr.md": STUB}, "fallback stub outside posts/"),
        ({"posts/x/index.md": ARTICLE, "posts/x/index.fr.md": STUB.replace("Hello", "Salut")}, "title 'Salut'"),
    ],
)
def test_content(tmp_path, files, msg):
    for rel, text in files.items():
        write(tmp_path / rel, text)
    res = subprocess.run([sys.executable, CHECK, "--content", str(tmp_path)], capture_output=True, text=True)
    assert (res.returncode == 0) is (msg is None), res.stdout
    if msg:
        assert msg in res.stdout


def test_site_content_translated():
    res = subprocess.run([sys.executable, CHECK, "--content", str(REPO / "site/content")], capture_output=True, text=True)
    assert res.returncode == 0, res.stdout


CHARTS_NAV = [
    ("Home", "https://nedsi.io/"),
    ("Blog", "https://blog.nedsi.io/"),
    ("Homelab", "https://homelab.nedsi.io/"),
    ("Tech radar", "https://techradar.nedsi.io/"),
    ("About", "https://blog.nedsi.io/about/"),
]
CHARTS_HOME = (
    '<main><h1>Drum charts</h1><table class="songs"><tbody><tr><td><a href="/tool-schism/">Schism</a></td>'
    '<td><a href="/pdf/tool-schism.pdf" download aria-label="Download the PDF of Schism">PDF</a></td></tr></tbody></table>'
    '<p class="updated"><a href="https://github.com/ned-si/drum-charts/releases/tag/charts-2026-11-26-4215d23">charts-2026-11-26-4215d23</a></p>'
    '<p class="credits"><a href="https://github.com/ned-si/drum-charts">GitHub</a></p></main>'
)
CHARTS_SONG = (
    '<main><h1>Schism</h1><p class="links"><a class="button" href="/pdf/tool-schism.pdf" download>Download the PDF</a></p>'
    '<div class="sheets"><img src="/pages/tool-schism-1.svg" width="595" height="842" alt="Schism by Tool, page 1 of 2">'
    '<img src="/pages/tool-schism-2.svg" width="595" height="842" alt="Schism by Tool, page 2 of 2" loading="lazy"></div></main>'
)


def charts_run(tmp_path, pages):
    """site_markup over English-only charts.nedsi.io pages (no French yet)."""
    for rel, body in pages.items():
        path = page_path(rel)
        start = f'<html lang="en-GB"><head><link rel="canonical" href="https://charts.nedsi.io{path}"><link rel="stylesheet" href="/theme.css"></head>'
        body = body.replace("</nav></header>", "</nav>" + prefs(path) + "</header>")
        write(tmp_path / rel, f"<!doctype html>{start}<body>{body}</body></html>")
    return subprocess.run([sys.executable, CHECK, str(tmp_path), "charts.nedsi.io"], capture_output=True, text=True)


def test_charts_pages_pass(tmp_path):
    pages = {"index.html": nav(links=CHARTS_NAV) + CHARTS_HOME, "tool-schism/index.html": nav(links=CHARTS_NAV) + CHARTS_SONG}
    res = charts_run(tmp_path, pages)
    assert res.returncode == 0, res.stdout


@pytest.mark.parametrize(
    "body, msg",
    [
        ('<audio controls src="/x.ogg"></audio>', "<audio> on charts.nedsi.io"),
        ('<a href="/pdf/tool-schism.mp3">MP3</a>', "audio on charts.nedsi.io"),
        ('<a href="https://github.com/ned-si/drum-charts/releases/download/x/tool-schism.MP3">MP3</a>', "audio on charts.nedsi.io"),
        ('<video><source src="/x.webm"></video>', "<source> on charts.nedsi.io"),
        ('<object data="/pdf/tool-schism.pdf"></object>', "<object> on charts.nedsi.io"),
    ],
)
def test_charts_media_fails(tmp_path, body, msg):
    res = charts_run(tmp_path, {"index.html": nav(links=CHARTS_NAV) + body})
    assert res.returncode == 1
    assert msg in res.stdout


def test_blog_picture_source_passes(tmp_path):
    body = nav("Blog") + '<article><picture><source srcset="/a.webp" type="image/webp"><img src="/a.jpg" alt="a"></picture></article>'
    res = run(tmp_path, {"index.html": body})
    assert res.returncode == 0, res.stdout
