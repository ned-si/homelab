"""platform/aws-exporter/exporter.py: SigV4 and collect() against canned AWS answers."""
from __future__ import annotations

import importlib.util
import json
from datetime import date, datetime, timezone
from pathlib import Path

SRC = Path(__file__).resolve().parent.parent / "platform" / "aws-exporter" / "exporter.py"

LIST_1 = b"""<?xml version="1.0" encoding="UTF-8"?>
<ListBucketResult xmlns="http://s3.amazonaws.com/doc/2006-03-01/">
<IsTruncated>true</IsTruncated><NextContinuationToken>t/2+=</NextContinuationToken>
<Contents><Key>immich/library/data/00/a</Key><Size>100</Size><StorageClass>GLACIER_IR</StorageClass></Contents>
<Contents><Key>immich/library/config</Key><Size>5</Size><StorageClass>STANDARD</StorageClass></Contents>
</ListBucketResult>"""
LIST_2 = b"""<?xml version="1.0" encoding="UTF-8"?>
<ListBucketResult xmlns="http://s3.amazonaws.com/doc/2006-03-01/">
<IsTruncated>false</IsTruncated>
<Contents><Key>cnpg/immich-db/wals/1</Key><Size>16</Size><StorageClass>STANDARD</StorageClass></Contents>
<Contents><Key>README</Key><Size>1</Size><StorageClass>STANDARD</StorageClass></Contents>
</ListBucketResult>"""


def day(start: str, s3: float, ce: float) -> dict:
    return {"TimePeriod": {"Start": start}, "Groups": [
        {"Keys": ["Amazon Simple Storage Service"], "Metrics": {"UnblendedCost": {"Amount": str(s3)}}},
        {"Keys": ["AWS Cost Explorer"], "Metrics": {"UnblendedCost": {"Amount": str(ce)}}}]}


COST = {"ResultsByTime": [day("2026-09-30", 1.0, 0.0), day("2026-10-01", 0.5, 0.02), day("2026-10-14", 0.25, 0.02)]}


def load(monkeypatch, **env):
    for k in ("AWS_ACCESS_KEY_ID", "AWS_SECRET_ACCESS_KEY"):
        monkeypatch.delenv(k, raising=False)
    for k, v in env.items():
        monkeypatch.setenv(k, v)
    spec = importlib.util.spec_from_file_location("aws_exporter", SRC)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    mod.calls = []

    def fake(method, host, path, query, headers, body, region, service):
        mod.calls.append((service, headers.get("x-amz-target", ""), query.get("continuation-token")))
        if service == "s3":
            return LIST_2 if query.get("continuation-token") else LIST_1
        target = headers["x-amz-target"]
        return json.dumps(COST if target.endswith("GetCostAndUsage") else {"Total": {"Amount": "3.0"}}).encode()
    mod.request = fake
    return mod


def metrics(text: str) -> dict[str, float]:
    return {line.rsplit(" ", 1)[0]: float(line.rsplit(" ", 1)[1])
            for line in text.splitlines() if line and not line.startswith("#")}


def test_collect(monkeypatch):
    mod = load(monkeypatch, AWS_ACCESS_KEY_ID="AKIDEXAMPLE", AWS_SECRET_ACCESS_KEY="secret")
    m = metrics(mod.collect(date(2026, 10, 15)))
    b = 'bucket="ned-si-homelab-backups"'
    assert m[f'aws_s3_prefix_bytes{{{b},prefix="immich/library",storage_class="GLACIER_IR"}}'] == 100
    assert m[f'aws_s3_prefix_bytes{{{b},prefix="immich/library",storage_class="STANDARD"}}'] == 5
    assert m[f'aws_s3_prefix_objects{{{b},prefix="cnpg/immich-db",storage_class="STANDARD"}}'] == 1
    assert m[f'aws_s3_prefix_bytes{{{b},prefix="(root)",storage_class="STANDARD"}}'] == 1
    s3 = 'service="Amazon Simple Storage Service"'
    assert m[f"aws_cost_yesterday_usd{{{s3}}}"] == 0.25
    assert m[f"aws_cost_month_to_date_usd{{{s3}}}"] == 0.75
    assert m[f"aws_cost_last_month_usd{{{s3}}}"] == 1.0
    assert abs(m['aws_cost_month_forecast_usd{method="cost_explorer"}'] - 3.79) < 1e-9
    assert m['aws_exporter_source_up{source="cost"}'] == 1
    assert m['aws_exporter_source_up{source="s3"}'] == 1


def test_cost_explorer_once_per_day(monkeypatch):
    mod = load(monkeypatch, AWS_ACCESS_KEY_ID="AKIDEXAMPLE", AWS_SECRET_ACCESS_KEY="secret")
    mod.collect(date(2026, 10, 15))
    mod.collect(date(2026, 10, 15))
    ce = [c for c in mod.calls if c[0] == "ce"]
    assert len(ce) == 2  # GetCostAndUsage + GetCostForecast, not repeated the same day
    assert 'aws_cost_month_forecast_usd' in mod.collect(date(2026, 10, 15))


def test_no_forecast_on_the_last_day(monkeypatch):
    mod = load(monkeypatch, AWS_ACCESS_KEY_ID="AKIDEXAMPLE", AWS_SECRET_ACCESS_KEY="secret")
    mod.collect(date(2026, 10, 31))
    assert not any(c[1].endswith("GetCostForecast") for c in mod.calls)


def test_linear_estimate_without_forecast_history(monkeypatch):
    import io
    import urllib.error
    mod = load(monkeypatch, AWS_ACCESS_KEY_ID="AKIDEXAMPLE", AWS_SECRET_ACCESS_KEY="secret")
    fake = mod.request

    def no_forecast(method, host, path, query, headers, body, region, service):
        if headers.get("x-amz-target", "").endswith("GetCostForecast"):
            raise urllib.error.HTTPError("https://ce", 400, "Bad Request", {},
                                         io.BytesIO(b'{"__type":"DataUnavailableException"}'))
        return fake(method, host, path, query, headers, body, region, service)
    mod.request = no_forecast
    m = metrics(mod.collect(date(2026, 10, 15)))
    # 0.79 spent in 14 days, 17 days left in October.
    assert abs(m['aws_cost_month_forecast_usd{method="linear"}'] - (0.79 + 0.79 / 14 * 17)) < 1e-3
    assert m['aws_exporter_source_up{source="cost"}'] == 1


def test_pending_key_skips_aws(monkeypatch):
    mod = load(monkeypatch, AWS_ACCESS_KEY_ID="PENDING-AWS_METRICS_ACCESS_KEY_ID", AWS_SECRET_ACCESS_KEY="x")
    m = metrics(mod.collect(date(2026, 10, 15)))
    assert m["aws_exporter_configured"] == 0
    assert not mod.calls


def test_sigv4_matches_the_aws_example(monkeypatch):
    # AWS SigV4 test suite, "get-vanilla" (without x-amz-content-sha256, which sign() always adds,
    # so only the scope and signed-header list are compared, plus a stable signature).
    mod = load(monkeypatch, AWS_ACCESS_KEY_ID="AKIDEXAMPLE",
               AWS_SECRET_ACCESS_KEY="wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY")
    now = datetime(2015, 8, 30, 12, 36, 0, tzinfo=timezone.utc)
    h = mod.sign("GET", "example.amazonaws.com", "/", {}, {}, b"", "us-east-1", "service", now)
    assert h["x-amz-date"] == "20150830T123600Z"
    assert h["authorization"].startswith(
        "AWS4-HMAC-SHA256 Credential=AKIDEXAMPLE/20150830/us-east-1/service/aws4_request, "
        "SignedHeaders=host;x-amz-content-sha256;x-amz-date, Signature=")
    assert h == mod.sign("GET", "example.amazonaws.com", "/", {}, {}, b"", "us-east-1", "service", now)
