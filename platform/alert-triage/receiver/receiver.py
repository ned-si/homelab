"""Alert-triage receiver: Alertmanager webhook in, Jobs out (stdlib only).

Spec alert-triage. For every firing notification of the `action=human`
route it starts one snapshot Job (scripts/alert-triage-job.sh, from a shallow
clone of main) and, when the alert name is in the fix table, that fix's Job.
A resolved notification is logged and starts nothing.

It holds no state: Alertmanager owns grouping, repeats (`repeat_interval`)
and resolution. The Job name is derived from the incident and a 10-minute
window, so Alertmanager retrying a notification hits AlreadyExists instead
of starting a second Job.

Untrusted input: only the alert name reaches a Job, as an environment
variable, and only if it matches ^[A-Za-z0-9]+$. Labels and annotations are
never copied anywhere.

Logs are JSON lines on stdout with `incident.id`, `alertname` and `event`
(received, snapshot, fix, resolved, failed); Vector ships them to the store.

Environment: PORT (8080), NAMESPACE (alert-triage), SNAPSHOT_IMAGE,
SNAPSHOT_SA (alert-triage-snapshot), REPO_URL, FIX_TABLE (path of the JSON
table, default /etc/alert-triage/fixes.json; missing means empty), AM_URL,
STORE_URL (passed to the Jobs).
"""
from __future__ import annotations

import hashlib
import json
import os
import re
import ssl
import sys
import time
import urllib.error
import urllib.request
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PORT = int(os.environ.get("PORT", "8080"))
NAMESPACE = os.environ.get("NAMESPACE", "alert-triage")
SNAPSHOT_IMAGE = os.environ.get("SNAPSHOT_IMAGE", "")
SNAPSHOT_SA = os.environ.get("SNAPSHOT_SA", "alert-triage-snapshot")
REPO_URL = os.environ.get("REPO_URL", "https://github.com/ned-si/homelab.git")
FIX_TABLE = os.environ.get("FIX_TABLE", "/etc/alert-triage/fixes.json")
JOB_ENV = ("AM_URL", "STORE_URL")
MAX_BODY = 1 << 20
WINDOW = 600

NAME_RE = re.compile(r"^[A-Za-z0-9]+$")
SA_DIR = "/var/run/secrets/kubernetes.io/serviceaccount"


def log(event: str, incident: str = "", alertname: str = "", **fields) -> None:
    rec = {"time": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"), "event": event,
           "incident.id": incident, "alertname": alertname, **fields}
    print(json.dumps(rec, sort_keys=True), flush=True)


def incident_id(group_key: str) -> str:
    return hashlib.sha256(group_key.encode()).hexdigest()[:16]


def alert_name(payload: dict) -> str:
    """The page's alert name: the group's, else the first action=human alert's."""
    name = (payload.get("groupLabels") or {}).get("alertname") or (payload.get("commonLabels") or {}).get("alertname")
    if not name:
        for a in payload.get("alerts") or []:
            labels = a.get("labels") or {}
            if labels.get("action") == "human":
                name = labels.get("alertname")
                break
    return name if isinstance(name, str) else ""


def load_table(path: str = FIX_TABLE) -> dict:
    """{alertname: {"serviceAccount", "image", "command": [...]}}; missing file: empty."""
    try:
        with open(path) as f:
            table = json.load(f)
    except FileNotFoundError:
        return {}
    for name, fix in table.items():
        if not NAME_RE.match(name) or not {"serviceAccount", "image", "command"} <= set(fix):
            raise ValueError(f"fix table entry {name!r}: alertname or fields invalid")
    return table


def _job(kind: str, name: str, incident: str, sa: str, image: str, command: list, env: dict) -> dict:
    labels = {"app.kubernetes.io/name": "alert-triage", "alert-triage/kind": kind, "alert-triage/incident": incident}
    return {
        "apiVersion": "batch/v1",
        "kind": "Job",
        "metadata": {"name": name, "namespace": NAMESPACE, "labels": labels},
        "spec": {
            "backoffLimit": 0,
            "activeDeadlineSeconds": 300,
            "ttlSecondsAfterFinished": 86400,
            "template": {
                "metadata": {"labels": labels},
                "spec": {
                    "serviceAccountName": sa,
                    "restartPolicy": "Never",
                    "securityContext": {"runAsNonRoot": True, "runAsUser": 65534, "runAsGroup": 65534,
                                        "seccompProfile": {"type": "RuntimeDefault"}},
                    "containers": [{
                        "name": kind,
                        "image": image,
                        "command": command,
                        "env": [{"name": k, "value": v} for k, v in sorted(env.items())],
                        "resources": {"requests": {"cpu": "50m", "memory": "64Mi"}, "limits": {"memory": "256Mi"}},
                        "securityContext": {"allowPrivilegeEscalation": False, "readOnlyRootFilesystem": True,
                                            "capabilities": {"drop": ["ALL"]}},
                        "volumeMounts": [{"name": "tmp", "mountPath": "/tmp"}],
                    }],
                    "volumes": [{"name": "tmp", "emptyDir": {"sizeLimit": "64Mi"}}],
                },
            },
        },
    }


def jobs_for(payload: dict, table: dict, now: float) -> tuple[str, str, list[dict]]:
    """(incident id, alert name, Jobs to create) for one notification.

    Raises ValueError("alertname rejected") for a name outside ^[A-Za-z0-9]+$.
    """
    incident = incident_id(str(payload.get("groupKey", "")))
    name = alert_name(payload)
    if not NAME_RE.match(name):
        raise ValueError("alertname rejected")
    if payload.get("status") != "firing":
        return incident, name, []
    suffix = f"{incident[:10]}-{int(now) // WINDOW}"
    fix = table.get(name)
    env = {"ALERTNAME": name, "INCIDENT_ID": incident, "FIX": name if fix else "none", "HOME": "/tmp"}
    env.update({k: os.environ[k] for k in JOB_ENV if os.environ.get(k)})
    snapshot = _job("snapshot", f"snapshot-{suffix}", incident, SNAPSHOT_SA, SNAPSHOT_IMAGE,
                    ["bash", "-c", 'git clone -q --depth 1 "$REPO_URL" /tmp/repo && exec bash /tmp/repo/scripts/alert-triage-job.sh'],
                    {**env, "REPO_URL": REPO_URL})
    jobs = [snapshot]
    if fix:
        jobs.append(_job("fix", f"fix-{suffix}", incident, fix["serviceAccount"], fix["image"], list(fix["command"]), env))
    return incident, name, jobs


def create_job(job: dict) -> str:
    """POST the Job with the pod's ServiceAccount: 'created' or 'exists'."""
    host = os.environ["KUBERNETES_SERVICE_HOST"]
    port = os.environ.get("KUBERNETES_SERVICE_PORT", "443")
    with open(f"{SA_DIR}/token") as f:
        token = f.read().strip()
    req = urllib.request.Request(
        f"https://{host}:{port}/apis/batch/v1/namespaces/{NAMESPACE}/jobs",
        data=json.dumps(job).encode(), method="POST",
        headers={"Authorization": f"Bearer {token}", "Content-Type": "application/json"})
    ctx = ssl.create_default_context(cafile=f"{SA_DIR}/ca.crt")
    try:
        with urllib.request.urlopen(req, timeout=10, context=ctx):
            return "created"
    except urllib.error.HTTPError as e:
        if e.code == 409:
            return "exists"
        raise


def handle(payload: dict, table: dict, create=create_job, now: float | None = None) -> int:
    """One notification: the HTTP status to answer (5xx makes Alertmanager retry)."""
    try:
        incident, name, jobs = jobs_for(payload, table, time.time() if now is None else now)
    except ValueError as e:
        log("failed", incident_id(str(payload.get("groupKey", ""))), "", msg=str(e))
        return 200
    status = payload.get("status", "")
    log("received", incident, name, status=status)
    if status == "resolved":
        log("resolved", incident, name)
        return 200
    for job in jobs:
        kind = job["metadata"]["labels"]["alert-triage/kind"]
        try:
            result = create(job)
        except Exception as e:  # noqa: BLE001 - any failure is logged and retried
            log("failed", incident, name, msg=f"{kind} job not created: {e}"[:300])
            return 500
        log(kind, incident, name, job=job["metadata"]["name"], result=result)
    return 200


class Handler(BaseHTTPRequestHandler):
    table: dict = {}

    def _reply(self, code: int) -> None:
        self.send_response(code)
        self.send_header("Content-Length", "0")
        self.end_headers()

    def do_GET(self) -> None:  # noqa: N802
        self._reply(200 if self.path == "/healthz" else 404)

    def do_POST(self) -> None:  # noqa: N802
        if self.path != "/webhook":
            return self._reply(404)
        length = int(self.headers.get("Content-Length") or 0)
        if not 0 < length <= MAX_BODY:
            return self._reply(413)
        try:
            payload = json.loads(self.rfile.read(length))
            if not isinstance(payload, dict):
                raise ValueError("not an object")
        except ValueError:
            log("failed", msg="body is not a JSON object")
            return self._reply(400)
        self._reply(handle(payload, self.table))

    def log_message(self, *args) -> None:  # access lines would not be JSON
        pass


def main() -> None:
    if not SNAPSHOT_IMAGE:
        sys.exit("SNAPSHOT_IMAGE is not set")
    Handler.table = load_table()
    log("started", msg=f"{len(Handler.table)} fix(es) in the table")
    ThreadingHTTPServer(("", PORT), Handler).serve_forever()


if __name__ == "__main__":
    main()
