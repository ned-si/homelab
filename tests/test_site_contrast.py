"""scripts/ci/site_contrast.py: both palettes against the contrast pairs."""
import shutil
import subprocess
import sys

from conftest import REPO, SCRIPTS

CHECK = str(SCRIPTS / "site_contrast.py")
PALETTE = REPO / "site/assets/css"


def run(path):
    return subprocess.run([sys.executable, CHECK, str(path)], capture_output=True, text=True)


def copy(tmp_path):
    for theme in ("dark", "light"):
        shutil.copy(PALETTE / f"theme-{theme}.css", tmp_path / f"theme-{theme}.css")
    return tmp_path


def edit(tmp_path, theme, old, new):
    f = tmp_path / f"theme-{theme}.css"
    text = f.read_text(encoding="utf-8")
    assert old in text
    f.write_text(text.replace(old, new), encoding="utf-8")


def test_palettes_pass():
    res = run(PALETTE)
    assert res.returncode == 0, res.stdout


def test_low_contrast_fails(tmp_path):
    """Acceptance criterion 4: a light --muted of #9aa0a6 fails."""
    edit(copy(tmp_path), "light", "--muted: #5b6065;", "--muted: #9aa0a6;")
    res = run(tmp_path)
    assert res.returncode == 1
    assert "light: --muted #9aa0a6 on --bg" in res.stdout


def test_property_in_no_pair_fails(tmp_path):
    copy(tmp_path)
    for theme in ("dark", "light"):
        edit(tmp_path, theme, "  --bg:", "  --shadow: #000000;\n  --bg:")
    res = run(tmp_path)
    assert res.returncode == 1
    assert "--shadow is in no contrast pair" in res.stdout


def test_missing_property_fails(tmp_path):
    edit(copy(tmp_path), "dark", "  --tile: #1a1c1f;\n", "")
    res = run(tmp_path)
    assert res.returncode == 1
    assert "dark: no --tile" in res.stdout
    assert "different properties" in res.stdout


def test_missing_file_fails(tmp_path):
    (copy(tmp_path) / "theme-light.css").unlink()
    assert run(tmp_path).returncode == 1


def test_rule_other_than_palette_fails(tmp_path):
    """Requirement 1.6: custom properties, color-scheme and the hiding rule only."""
    copy(tmp_path)
    with open(tmp_path / "theme-dark.css", "a", encoding="utf-8") as f:
        f.write("body { margin: 0; }\n")
    res = run(tmp_path)
    assert res.returncode == 1
    assert "theme-dark.css" in res.stdout
