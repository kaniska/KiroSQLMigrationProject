#!/usr/bin/env python3
"""
migkit.audit — structured, tamper-evident audit logging with correlation ids.

Every record is one JSON line (JSON Lines) shaped after the OpenTelemetry log data model:

  {"timestamp": "2026-09-14T09:12:03.418Z",           RFC 3339, UTC, milliseconds
   "severity_text": "INFO", "severity_number": 9,     OTel severity
   "event": "infa.extract.end",                       stable, dotted event name
   "body": "extracted 4 SQL attribute(s)",            human text (secrets redacted)
   "run_id": "3f0c…", "trace_id": "3f0c…(32 hex)",    correlation: one run of the pipeline
   "span_id": "a1b2…(16 hex)", "parent_span_id": …,   one tool invocation / step
   "traceparent": "00-<trace_id>-<span_id>-01",       W3C Trace Context, for other systems
   "resource": {"service.name": …, "service.version": …, "host.name": …, "user.name": …, "process.pid": …},
   "attributes": {…},                                 event details (lineage, counts, hashes, rule ids)
   "seq": 17, "prev_hash": "…", "hash": "…"}          sha256 chain → `audit.py verify` detects edits

Correlation
  * MIGRATION_RUN_ID   — set once per run (supporting-files/run_tests.sh, supporting-files/kiro_migrate.sh, agent session);
                         32 lowercase hex chars (a UUID without dashes). Generated when absent.
  * TRACEPARENT        — W3C traceparent of the calling step; child spans use its span id as parent.
  * Child processes inherit both through child_env().
  * PostgreSQL: pgtest.sh sets application_name=mig:<skill>:<run_id[:8]> and the GUC migration.run_id.

Never logged: passwords, tokens, keys, connection strings with credentials (redacted by key name and
by value pattern), full SQL bodies or data rows (log sha256 + length + path instead). Strings are
length-capped; JSON encoding neutralises CR/LF log injection.

CLI
  audit.py emit   --event E [--severity INFO] [--body TEXT] [--attr k=v ...]
  audit.py verify [FILE ...]        check the hash chain(s); exit 1 on a broken chain
  audit.py tail   [--run RUN_ID] [--event PREFIX] [-n N]
  audit.py new-run-id
"""
import argparse
import contextlib
import datetime as _dt
import getpass
import hashlib
import json
import os
import pathlib
import re
import sys
import time
import uuid


try:
    from . import __version__ as KIT_VERSION  # type: ignore
    from .platform_compat import file_lock, host_name, utf8_stdio  # type: ignore
except ImportError:  # executed as a script
    sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent.parent))
    from migkit import __version__ as KIT_VERSION  # type: ignore
    from migkit.platform_compat import file_lock, host_name, utf8_stdio  # type: ignore

SEVERITY = {"TRACE": 1, "DEBUG": 5, "INFO": 9, "NOTICE": 10, "WARN": 13, "ERROR": 17, "CRITICAL": 21}
MAX_STR = 2000
GENESIS = "0" * 64
SECRET_KEY_RE = re.compile(r"(pass(word)?|pwd|secret|token|api[_-]?key|access[_-]?key|private[_-]?key|credential|authorization|cookie|session[_-]?key)", re.I)
SECRET_VALUE_RES = [
    (re.compile(r"\b(AKIA|ASIA)[0-9A-Z]{16}\b"), "[REDACTED:aws-access-key-id]"),
    (re.compile(r"-----BEGIN [A-Z ]*PRIVATE KEY-----.*?(-----END [A-Z ]*PRIVATE KEY-----|$)", re.S), "[REDACTED:private-key]"),
    (re.compile(r"(?i)\b([A-Za-z_]*(?:password|pwd|passwd|secret|token|api[_-]?key))\s*[=:]\s*(\"[^\"]*\"|'[^']*'|[^\s;,&]+)"), r"\1=[REDACTED]"),
    (re.compile(r"(?i)(postgres(ql)?|mysql|mssql|sqlserver|jdbc:[a-z]+)://([^:/@\s]+):([^@\s]+)@"), r"\1://\3:[REDACTED]@"),
    (re.compile(r"(?i)X-Amz-Signature=[0-9a-f]{16,}"), "X-Amz-Signature=[REDACTED]"),       # RDS IAM auth tokens
    (re.compile(r"(?i)X-Amz-Security-Token=[^&\s]+"), "X-Amz-Security-Token=[REDACTED]"),
]


# ------------------------------------------------------------------ helpers
def now_rfc3339() -> str:
    t = _dt.datetime.now(_dt.timezone.utc)
    return t.strftime("%Y-%m-%dT%H:%M:%S.") + f"{t.microsecond // 1000:03d}Z"


def new_run_id() -> str:
    return uuid.uuid4().hex


def _valid_hex(s, n):
    return isinstance(s, str) and len(s) == n and re.fullmatch(r"[0-9a-f]+", s) and s.strip("0") != ""


SESSION_MAX_AGE_SECONDS = 12 * 3600


def session_file(root=None) -> pathlib.Path:
    return workspace_root(root) / "logs" / "state" / "current_session.json"


def active_session_run_id(root=None):
    """Run id of the active Kiro agent session (written by the agentSpawn hook), if fresh."""
    if os.environ.get("MIGRATION_INHERIT_SESSION", "1") == "0":
        return None
    f = session_file(root)
    try:
        d = json.loads(f.read_text(encoding="utf-8"))
        if time.time() - float(d.get("epoch", 0)) < SESSION_MAX_AGE_SECONDS and _valid_hex(d.get("run_id", ""), 32) and not d.get("ended"):
            return d["run_id"]
    except (OSError, ValueError, TypeError):
        return None
    return None


def run_id() -> str:
    """Correlation id resolution: MIGRATION_RUN_ID → active agent session → new id (exported)."""
    rid = os.environ.get("MIGRATION_RUN_ID", "").strip().lower().replace("-", "")
    if not _valid_hex(rid, 32):
        rid = active_session_run_id() or new_run_id()
        os.environ["MIGRATION_RUN_ID"] = rid
    return rid


def parent_span_id():
    tp = os.environ.get("TRACEPARENT", "")
    m = re.fullmatch(r"00-([0-9a-f]{32})-([0-9a-f]{16})-[0-9a-f]{2}", tp.strip())
    return m.group(2) if m else None


def workspace_root(start=None) -> pathlib.Path:
    p = pathlib.Path(start or os.getcwd()).resolve()
    for c in [p, *p.parents]:
        if (c / ".kiro").is_dir():
            return c
    return p


def log_dir() -> pathlib.Path:
    d = os.environ.get("MIGRATION_LOG_DIR")
    return pathlib.Path(d) if d else workspace_root() / "logs" / "audit"


def sha256_bytes(b: bytes) -> str:
    return hashlib.sha256(b).hexdigest()


def sha256_file(path) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def redact(value, key: str = ""):
    """Redact secrets by key name and by value pattern; cap string length; recurse into containers."""
    if key and SECRET_KEY_RE.search(key) and not isinstance(value, (dict, list, tuple)) \
            and not re.search(r"(count|sha256|hash|rule|finding|path|file|name_?only)$", key, re.I):
        return "[REDACTED]" if value not in (None, "", [], {}) else value
    if isinstance(value, dict):
        return {k: redact(v, str(k)) for k, v in value.items()}
    if isinstance(value, (list, tuple)):
        return [redact(v, key) for v in value]
    if isinstance(value, str):
        s = value
        for rx, rep in SECRET_VALUE_RES:
            s = rx.sub(rep, s)
        if len(s) > MAX_STR:
            s = s[:MAX_STR] + f"…[truncated {len(s) - MAX_STR} chars]"
        return s
    return value


# ------------------------------------------------------------------ logger
class AuditLogger:
    def __init__(self, service: str, directory=None, stderr_level: str = None):
        self.service = service
        self.directory = pathlib.Path(directory) if directory else log_dir()
        self.run_id = run_id()
        self.span_id = uuid.uuid4().hex[:16]
        self.parent_span_id = parent_span_id()
        self.stderr_level = SEVERITY.get((stderr_level or os.environ.get("MIGRATION_LOG_STDERR", "")).upper(), 99)
        self.resource = {
            "service.name": service,
            "service.version": KIT_VERSION,
            "host.name": host_name(),
            "user.name": _safe_user(),
            "process.pid": os.getpid(),
        }

    # the file name is per UTC day; records of all services share it so one run reads in order
    def path(self) -> pathlib.Path:
        return self.directory / f"audit-{_dt.datetime.now(_dt.timezone.utc):%Y%m%d}.jsonl"

    def traceparent(self) -> str:
        return f"00-{self.run_id}-{self.span_id}-01"

    def child_env(self, env=None) -> dict:
        e = dict(os.environ if env is None else env)
        e["MIGRATION_RUN_ID"] = self.run_id
        e["TRACEPARENT"] = self.traceparent()
        return e

    def log(self, event: str, body: str = "", severity: str = "INFO", **attributes) -> dict:
        rec = {
            "timestamp": now_rfc3339(),
            "severity_text": severity.upper(),
            "severity_number": SEVERITY.get(severity.upper(), 9),
            "event": event,
            "body": redact(body),
            "run_id": self.run_id,
            "trace_id": self.run_id,
            "span_id": self.span_id,
            "parent_span_id": self.parent_span_id,
            "traceparent": self.traceparent(),
            "resource": self.resource,
            "attributes": redact(attributes),
        }
        self._append(rec)
        if rec["severity_number"] >= self.stderr_level:
            print(f"[{rec['timestamp']}] {rec['severity_text']} {event} run={self.run_id[:8]} {rec['body']}", file=sys.stderr)
        return rec

    def _append(self, rec: dict):
        """Append one record. Binary I/O under an inter-process lock: identical bytes and LF line
        endings on Windows, Linux and macOS, and a gap-free hash chain across processes."""
        self.directory.mkdir(parents=True, exist_ok=True)
        p = self.path()
        with file_lock(p):
            seq, prev = _last_seq_hash(p)
            rec["seq"] = seq + 1
            rec["prev_hash"] = prev
            rec["hash"] = _record_hash(rec)
            line = (json.dumps(rec, ensure_ascii=False, sort_keys=False, separators=(",", ":")) + "\n").encode("utf-8")
            with open(p, "ab") as f:
                f.write(line)
                f.flush()
                os.fsync(f.fileno())

    @contextlib.contextmanager
    def span(self, name: str, **attributes):
        """Log <name>.start / <name>.end (duration_ms, status) — and <name>.error on exceptions."""
        t0 = time.monotonic()
        self.log(f"{name}.start", **attributes)
        outcome = {"status": "ok"}
        try:
            yield outcome
        except SystemExit as ex:
            outcome["status"] = "ok" if ex.code in (0, None) else "failed"
            outcome["exit_code"] = ex.code
            raise
        except BaseException as ex:  # noqa: BLE001 — logged and re-raised
            outcome["status"] = "error"
            self.log(f"{name}.error", body=f"{type(ex).__name__}: {ex}", severity="ERROR", error_type=type(ex).__name__)
            raise
        finally:
            sev = "INFO" if outcome.get("status") == "ok" else "ERROR"
            extra = {k: v for k, v in outcome.items()}
            self.log(f"{name}.end", severity=sev, duration_ms=round((time.monotonic() - t0) * 1000, 1), **extra)


def _safe_user():
    try:
        return getpass.getuser()
    except Exception:  # noqa: BLE001
        return "unknown"


def _record_hash(rec: dict) -> str:
    material = {k: v for k, v in rec.items() if k != "hash"}
    return sha256_bytes(json.dumps(material, ensure_ascii=False, sort_keys=True, separators=(",", ":")).encode("utf-8"))


def _last_seq_hash(path):
    """seq and hash of the last complete record of a log file; (0, GENESIS) when empty or missing."""
    try:
        with open(path, "rb") as f:
            f.seek(0, os.SEEK_END)
            end = f.tell()
            if end == 0:
                return 0, GENESIS
            size = min(end, 65536)
            f.seek(end - size)
            tail = f.read(size)
    except FileNotFoundError:
        return 0, GENESIS
    lines = [l for l in tail.splitlines() if l.strip()]
    if not lines:
        return 0, GENESIS
    try:
        last = json.loads(lines[-1].decode("utf-8"))
        return int(last.get("seq", 0)), last.get("hash", GENESIS)
    except (ValueError, TypeError, UnicodeDecodeError):
        return 0, sha256_bytes(lines[-1])                      # a corrupt tail line still anchors the chain


def verify_file(path) -> list:
    """Return a list of problems in a log file's hash chain (empty list = intact)."""
    problems, prev, seq = [], GENESIS, 0
    with open(path, encoding="utf-8", newline="") as f:
        for n, line in enumerate(f, 1):
            if not line.strip():
                continue
            try:
                rec = json.loads(line)
            except ValueError:
                problems.append(f"{path}:{n}: not valid JSON"); prev = sha256_bytes(line.rstrip("\r\n").encode("utf-8")); continue
            if rec.get("prev_hash") != prev:
                problems.append(f"{path}:{n}: prev_hash does not match the previous record (inserted/deleted/reordered line)")
            if rec.get("seq") != seq + 1:
                problems.append(f"{path}:{n}: seq {rec.get('seq')} (expected {seq + 1})")
            if _record_hash(rec) != rec.get("hash"):
                problems.append(f"{path}:{n}: hash mismatch (record was modified)")
            prev, seq = rec.get("hash", ""), int(rec.get("seq") or seq + 1)
    return problems


# ------------------------------------------------------------------ CLI
def _parse_attr(kv: str):
    k, _, v = kv.partition("=")
    try:
        return k, json.loads(v)
    except ValueError:
        return k, v


def main(argv=None):
    utf8_stdio()
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    e = sub.add_parser("emit"); e.add_argument("--service", default="shell"); e.add_argument("--event", required=True)
    e.add_argument("--severity", default="INFO"); e.add_argument("--body", default=""); e.add_argument("--attr", action="append", default=[])
    v = sub.add_parser("verify"); v.add_argument("files", nargs="*")
    t = sub.add_parser("tail"); t.add_argument("--run"); t.add_argument("--event"); t.add_argument("-n", type=int, default=50)
    sub.add_parser("new-run-id")
    sub.add_parser("current-run-id")
    a = ap.parse_args(argv)
    if a.cmd == "new-run-id":
        print(new_run_id()); return 0
    if a.cmd == "current-run-id":
        print(run_id()); return 0
    if a.cmd == "emit":
        AuditLogger(a.service).log(a.event, a.body, a.severity, **dict(_parse_attr(x) for x in a.attr)); return 0
    if a.cmd == "verify":
        files = [pathlib.Path(f) for f in a.files] or sorted(log_dir().glob("audit-*.jsonl"))
        bad = 0
        for f in files:
            probs = verify_file(f)
            print(f"{'OK  ' if not probs else 'FAIL'} {f}" + ("" if not probs else "\n  " + "\n  ".join(probs[:20])))
            bad += bool(probs)
        return 1 if bad else 0
    if a.cmd == "tail":
        recs = []
        for f in sorted(log_dir().glob("audit-*.jsonl")):
            for line in open(f, encoding="utf-8"):
                try:
                    r = json.loads(line)
                except ValueError:
                    continue
                if a.run and not r.get("run_id", "").startswith(a.run):
                    continue
                if a.event and not r.get("event", "").startswith(a.event):
                    continue
                recs.append(r)
        for r in recs[-a.n:]:
            print(f"{r['timestamp']} {r['severity_text']:<5} {r['run_id'][:8]} {r['span_id'][:6]} {r['event']:<34} {r.get('body','')}")
        return 0


if __name__ == "__main__":
    sys.exit(main())
