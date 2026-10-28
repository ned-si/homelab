"""platform/usage-exporter/exporter.py: collect() against canned API answers."""
from __future__ import annotations

import importlib.util
from pathlib import Path

SRC = Path(__file__).resolve().parent.parent / "platform" / "usage-exporter" / "exporter.py"

ANSWERS = {
    "/api/server/statistics": {"photos": 10, "videos": 2, "usage": 1000, "usageByUser": [
        {"userId": "u1", "userName": "alice", "photos": 7, "videos": 1, "usage": 600, "quotaSizeInBytes": None},
        {"userId": "u2", "userName": "bob", "photos": 3, "videos": 1, "usage": 400, "quotaSizeInBytes": 5000},
        {"userId": "u3", "userName": "bob", "photos": 0, "videos": 0, "usage": 0, "quotaSizeInBytes": None}]},
    "/Items/Counts": {"MovieCount": 5, "SeriesCount": 2, "EpisodeCount": 40, "ItemCount": 47},
    "/Sessions": [{"UserName": "alice", "NowPlayingItem": {"Type": "Movie"}},
                  {"UserName": "alice", "NowPlayingItem": {"Type": "Episode"}},
                  {"UserName": "bob"}],
}


def load(monkeypatch, **env):
    for k in ("IMMICH_API_KEY", "JELLYFIN_API_KEY"):
        monkeypatch.delenv(k, raising=False)
    for k, v in env.items():
        monkeypatch.setenv(k, v)
    spec = importlib.util.spec_from_file_location("usage_exporter", SRC)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    mod.get = lambda url, headers: next(v for k, v in ANSWERS.items() if k in url)
    return mod


def metrics(text: str) -> dict[str, float]:
    return {line.rsplit(" ", 1)[0]: float(line.rsplit(" ", 1)[1])
            for line in text.splitlines() if line and not line.startswith("#")}


def test_both_sources(monkeypatch):
    m = metrics(load(monkeypatch, IMMICH_API_KEY="k1", JELLYFIN_API_KEY="k2").collect())
    assert m['immich_assets{type="photo"}'] == 10
    assert m['immich_user_assets{type="video",user="bob",user_id="u2"}'] == 1
    assert m['immich_user_assets{type="video",user="bob",user_id="u3"}'] == 0
    assert m['immich_user_usage_bytes{user="alice",user_id="u1"}'] == 600
    assert m['immich_user_quota_bytes{user="bob",user_id="u2"}'] == 5000
    assert 'immich_user_quota_bytes{user="alice",user_id="u1"}' not in m
    assert m['jellyfin_items{type="movie"}'] == 5
    assert m['jellyfin_items{type="item"}'] == 47
    assert m["jellyfin_streams"] == 2
    assert m['jellyfin_user_streams{type="movie",user="alice"}'] == 1
    assert m['usage_source_up{source="immich"}'] == 1


def test_pending_key_skips_the_source(monkeypatch):
    m = metrics(load(monkeypatch, IMMICH_API_KEY="PENDING-USAGE_IMMICH_API_KEY").collect())
    assert m['usage_source_configured{source="immich"}'] == 0
    assert m['usage_source_configured{source="jellyfin"}'] == 0
    assert not any(k.startswith(("immich_", "jellyfin_", "usage_source_up")) for k in m)


def test_jellyfin_uses_the_authorization_header(monkeypatch):
    mod = load(monkeypatch, JELLYFIN_API_KEY="k2")
    seen = []

    def get(url, headers):
        seen.append((url, headers))
        return next(v for k, v in ANSWERS.items() if k in url)
    mod.get = get
    mod.collect()
    assert seen and all(h == {"Authorization": 'MediaBrowser Token="k2"'} for _, h in seen)


def test_failing_source_is_down(monkeypatch):
    mod = load(monkeypatch, IMMICH_API_KEY="k1")

    def boom(url, headers):
        raise OSError("refused")
    mod.get = boom
    m = metrics(mod.collect())
    assert m['usage_source_up{source="immich"}'] == 0
