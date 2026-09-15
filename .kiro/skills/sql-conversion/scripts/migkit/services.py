#!/usr/bin/env python3
"""
migkit.services — AWS service integrations with automatic local fallback.

| Concern     | AWS backend                           | Local fallback (always written first)          |
|-------------|---------------------------------------|------------------------------------------------|
| audit       | Amazon CloudWatch Logs (PutLogEvents) | logs/audit/audit-YYYYMMDD.jsonl (hash-chained) |
| lineage     | Amazon DataZone PostLineageEvent      | logs/state/lineage.jsonl (local JSON db)       |
| guardrail   | Amazon Bedrock Guardrails ApplyGuardrail | migkit.security deterministic scanner       |
| archive     | Amazon S3 (Object Lock retention)     | logs/archive/<run_id>/ + sha256 manifest       |
| secrets     | AWS Secrets Manager (DB credentials)  | environment (PGPASSWORD) / RDS IAM token       |

Configuration (first found wins, then environment overrides):
  $MIGRATION_SERVICES_CONFIG
  <workspace>/.kiro/settings/migration-services.json   (Kiro denies agent writes to .kiro/settings)
  built-in defaults (every backend "auto" with no AWS resource configured → local)

  backend per concern:  "auto"  use AWS when configured and a read-only probe succeeds, else local
                        "aws"   AWS required — fail when unavailable
                        "local" never call AWS
  env overrides:        MIGRATION_OFFLINE=1 (everything local)
                        MIGRATION_<CONCERN>_BACKEND=auto|aws|local   e.g. MIGRATION_AUDIT_BACKEND=local

Calls go through the AWS CLI v2 (no boto3 dependency) with connect/read timeouts, using the caller's
AWS credentials. Probes are read-only and cached (probe_cache_seconds). Nothing here creates AWS
resources: log groups, guardrails, DataZone domains and buckets are created by an administrator
(see references/aws-services.md). Secret values are never printed or logged.

CLI
  services.py status                     resolved backend per concern (+ reason)
  services.py probe [--refresh]          run the read-only probes
  services.py sync                       ship pending audit records, lineage events and archives to AWS
  services.py lineage-emit EVENT.json    store locally and post to DataZone when available
  services.py guardrail PATH...          local scan + Bedrock ApplyGuardrail when available
  services.py archive PATH...            archive files (S3 when available, else local)
  services.py exec -- CMD ARGS...        run CMD with DB credentials from Secrets Manager in its env
  services.py show-config                effective configuration (no secrets)
"""
import argparse
import copy
import datetime as dt
import hashlib
import json
import os
import pathlib
import shutil
import subprocess
import sys
import tempfile
import time

try:
    from .audit import AuditLogger, workspace_root, sha256_file, now_rfc3339, redact  # type: ignore
    from .localdb import LocalStore  # type: ignore
    from . import security  # type: ignore
    from .platform_compat import host_name, utf8_stdio  # type: ignore
except ImportError:  # run as a script
    sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent.parent))
    from migkit.audit import AuditLogger, workspace_root, sha256_file, now_rfc3339, redact  # type: ignore
    from migkit.localdb import LocalStore  # type: ignore
    from migkit import security  # type: ignore
    from migkit.platform_compat import host_name, utf8_stdio  # type: ignore

CONCERNS = ("audit", "lineage", "guardrail", "archive", "secrets")
DEFAULTS = {
    "region": None,                      # None → AWS_REGION / AWS CLI default region
    "aws_cli": "aws",
    "aws_profile": None,
    "timeout_seconds": 10,
    "probe_cache_seconds": 300,
    "state_dir": "logs/state",
    "audit": {"backend": "auto",
              "cloudwatch": {"log_group": None, "log_stream_prefix": "kiro-sql-migration", "max_batch_events": 5000},
              "local": {"dir": "logs/audit"}},
    "lineage": {"backend": "auto",
                "datazone": {"domain_identifier": None},
                "local": {"collection": "lineage"},
                "namespace": "kiro-sql-migration"},
    "guardrail": {"backend": "auto",
                  "bedrock": {"guardrail_identifier": None, "guardrail_version": "DRAFT", "max_chars_per_call": 20000,
                              "max_chars_per_run": 400000},
                  "local": {"fail_on": "high"}},
    "archive": {"backend": "auto",
                "s3": {"bucket": None, "prefix": "kiro-sql-migration/", "object_lock_mode": None, "retention_days": 365,
                       "sse": "aws:kms", "kms_key_id": None},
                "local": {"dir": "logs/archive"}},
    "secrets": {"backend": "auto",
                "secretsmanager": {"secret_id": None},
                "local": {"env": "PGPASSWORD"}},
}
REQUIRED = {"audit": ("cloudwatch", "log_group"), "lineage": ("datazone", "domain_identifier"),
            "guardrail": ("bedrock", "guardrail_identifier"), "archive": ("s3", "bucket"),
            "secrets": ("secretsmanager", "secret_id")}
AWS_NAMES = {"audit": "Amazon CloudWatch Logs", "lineage": "Amazon DataZone", "guardrail": "Amazon Bedrock Guardrails",
             "archive": "Amazon S3", "secrets": "AWS Secrets Manager"}


class ServiceUnavailable(RuntimeError):
    pass


def _merge(base, over):
    out = copy.deepcopy(base)
    for k, v in (over or {}).items():
        out[k] = _merge(out[k], v) if isinstance(v, dict) and isinstance(out.get(k), dict) else v
    return out


def load_config(root=None) -> dict:
    root = pathlib.Path(root) if root else workspace_root()
    cfg, source = copy.deepcopy(DEFAULTS), "defaults"
    for cand in [os.environ.get("MIGRATION_SERVICES_CONFIG"), root / ".kiro" / "settings" / "migration-services.json"]:
        if cand and pathlib.Path(cand).is_file():
            user = json.loads(pathlib.Path(cand).read_text(encoding="utf-8"))
            user = {k: v for k, v in user.items() if not k.startswith("_")}
            cfg, source = _merge(cfg, user), str(cand)
            break
    if os.environ.get("MIGRATION_OFFLINE", "") in ("1", "true", "yes"):
        for c in CONCERNS:
            cfg[c]["backend"] = "local"
    for c in CONCERNS:
        v = os.environ.get(f"MIGRATION_{c.upper()}_BACKEND")
        if v:
            cfg[c]["backend"] = v.lower()
    for c in CONCERNS:
        if cfg[c]["backend"] not in ("auto", "aws", "local"):
            raise ValueError(f"{c}.backend must be auto|aws|local, got {cfg[c]['backend']!r}")
    if os.environ.get("MIGRATION_STATE_DIR"):
        cfg["state_dir"] = os.environ["MIGRATION_STATE_DIR"]
    if os.environ.get("MIGRATION_LOG_DIR"):
        cfg["audit"]["local"]["dir"] = os.environ["MIGRATION_LOG_DIR"]
    cfg["_source"], cfg["_root"] = source, str(root)
    return cfg


class Services:
    def __init__(self, config=None, logger=None):
        self.cfg = config or load_config()
        self.root = pathlib.Path(self.cfg["_root"])
        self.log = logger or AuditLogger("migkit.services")
        self.db = LocalStore(self._path(self.cfg["state_dir"]))
        self._resolved = {}
        self._guardrail_chars = 0

    # ------------------------------------------------------------ plumbing
    def _path(self, p) -> pathlib.Path:
        p = pathlib.Path(p)
        return p if p.is_absolute() else self.root / p

    def aws(self, *args, input_json=None, timeout=None, capture_secret=False) -> dict:
        """Run an AWS CLI command; returns parsed JSON. Raises ServiceUnavailable on any failure."""
        cmd = [self.cfg["aws_cli"], *args, "--output", "json",
               "--cli-connect-timeout", str(self.cfg["timeout_seconds"]), "--cli-read-timeout", str(self.cfg["timeout_seconds"])]
        if self.cfg.get("region"):
            cmd += ["--region", self.cfg["region"]]
        if self.cfg.get("aws_profile"):
            cmd += ["--profile", self.cfg["aws_profile"]]
        tmp = None
        try:
            if input_json is not None:
                tmp = tempfile.NamedTemporaryFile("w", suffix=".json", delete=False, encoding="utf-8")
                json.dump(input_json, tmp); tmp.close()
                cmd += ["--cli-input-json", f"file://{tmp.name}"]
            env = dict(os.environ, AWS_PAGER="")
            if shutil.which(cmd[0]) is None:
                raise ServiceUnavailable("AWS CLI not found")
            r = subprocess.run(cmd, capture_output=True, text=True, timeout=(timeout or self.cfg["timeout_seconds"]) * 3, env=env)
        except subprocess.TimeoutExpired:
            raise ServiceUnavailable(f"timeout: aws {args[0]} {args[1] if len(args) > 1 else ''}")
        finally:
            if tmp:
                os.unlink(tmp.name)
        if r.returncode != 0:
            err = redact((r.stderr or r.stdout or "").strip().splitlines()[-1:] or ["unknown error"])[0]
            raise ServiceUnavailable(f"aws {args[0]} {args[1] if len(args) > 1 else ''}: {err}")
        try:
            return json.loads(r.stdout) if r.stdout.strip() else {}
        except ValueError:
            return {} if capture_secret else {"raw": r.stdout[:200]}

    # ------------------------------------------------------------ resolution
    def _probe(self, concern: str):
        sect, key = REQUIRED[concern]
        c = self.cfg[concern][sect]
        ident = c[key]
        if concern == "audit":
            out = self.aws("logs", "describe-log-groups", "--log-group-name-prefix", ident, "--limit", "5")
            if not any(g.get("logGroupName") == ident for g in out.get("logGroups", [])):
                raise ServiceUnavailable(f"log group {ident} not found")
        elif concern == "lineage":
            self.aws("datazone", "get-domain", "--identifier", ident)
        elif concern == "guardrail":
            self.aws("bedrock", "get-guardrail", "--guardrail-identifier", ident, "--guardrail-version", c.get("guardrail_version") or "DRAFT")
        elif concern == "archive":
            self.aws("s3api", "head-bucket", "--bucket", ident)
        elif concern == "secrets":
            self.aws("secretsmanager", "describe-secret", "--secret-id", ident)

    def resolve(self, concern: str, refresh=False) -> dict:
        """{'backend': 'aws'|'local', 'reason': str}. auto falls back; aws raises."""
        if concern in self._resolved and not refresh:
            return self._resolved[concern]
        mode = self.cfg[concern]["backend"]
        sect, key = REQUIRED[concern]
        ident = self.cfg[concern][sect].get(key)
        res = None
        if mode == "local":
            res = {"backend": "local", "reason": "configured local"}
        elif not ident:
            if mode == "aws":
                raise ServiceUnavailable(f"{concern}: backend=aws but {sect}.{key} is not configured")
            res = {"backend": "local", "reason": f"{AWS_NAMES[concern]} not configured ({sect}.{key})"}
        else:
            cache_key = hashlib.sha256(json.dumps([concern, self.cfg[concern][sect], self.cfg.get("region"), self.cfg.get("aws_profile")],
                                                  sort_keys=True).encode()).hexdigest()[:16]
            cached = [d for d in self.db.find("probe_cache", key=cache_key)
                      if time.time() - d.get("epoch", 0) < self.cfg["probe_cache_seconds"]]
            if cached and not refresh:
                ok, why = cached[-1]["ok"], cached[-1]["reason"]
            else:
                try:
                    self._probe(concern); ok, why = True, f"{AWS_NAMES[concern]} reachable"
                except ServiceUnavailable as ex:
                    ok, why = False, str(ex)
                self.db.put("probe_cache", {"key": cache_key, "concern": concern, "ok": ok, "reason": why, "epoch": time.time()})
            if ok:
                res = {"backend": "aws", "reason": why}
            elif mode == "aws":
                raise ServiceUnavailable(f"{concern}: {why}")
            else:
                res = {"backend": "local", "reason": f"fallback: {why}"}
                self.log.log("services.fallback", f"{concern}: using local store", "WARN", concern=concern, reason=why,
                             aws_service=AWS_NAMES[concern])
        self._resolved[concern] = res
        return res

    # ------------------------------------------------------------ audit → CloudWatch Logs
    def ship_audit(self) -> dict:
        res = self.resolve("audit")
        if res["backend"] != "aws":
            return {"shipped": 0, "backend": "local", "reason": res["reason"]}
        c = self.cfg["audit"]["cloudwatch"]
        adir = self._path(self.cfg["audit"]["local"]["dir"])
        shipped = 0
        for f in sorted(adir.glob("audit-*.jsonl")):
            state = (self.db.find("audit_shipping", file=f.name) or [None])[-1]
            offset = state["offset"] if state else 0
            lines = f.read_text(encoding="utf-8").splitlines()[offset:]
            if not lines:
                continue
            # CloudWatch rejects events older than 14 days, so a file that old is marked shipped and skipped
            day = dt.datetime.strptime(f.stem.replace("audit-", ""), "%Y%m%d").replace(tzinfo=dt.timezone.utc)
            if dt.datetime.now(dt.timezone.utc) - day > dt.timedelta(days=13):
                self.log.log("services.audit.too_old", f"{f.name} is older than the CloudWatch 14-day limit; kept locally only", "WARN", file=f.name)
                self._save_offset(state, f.name, offset + len(lines))
                continue
            stream = f"{c['log_stream_prefix']}/{f.stem.replace('audit-', '')}/{host_name()}"
            try:
                self.aws("logs", "create-log-stream", "--log-group-name", c["log_group"], "--log-stream-name", stream)
            except ServiceUnavailable as ex:
                if "ResourceAlreadyExists" not in str(ex):
                    raise
            events = []
            for line in lines:
                try:
                    ts = dt.datetime.strptime(json.loads(line)["timestamp"], "%Y-%m-%dT%H:%M:%S.%fZ").replace(tzinfo=dt.timezone.utc)
                    ms = int(ts.timestamp() * 1000)
                except (ValueError, KeyError):
                    ms = int(time.time() * 1000)
                ev_size = len(line.encode("utf-8")) + 26
                if ev_size > 1_000_000:
                    line = line[:900_000]; ev_size = len(line.encode("utf-8")) + 26
                events.append((ms, line, ev_size))
            # PutLogEvents: chronological order, ≤ 1,048,576 bytes (26 bytes overhead/event), ≤ 10,000 events, ≤ 24 h span
            events.sort(key=lambda e: e[0])
            batch, size, sent = [], 0, 0
            for ms, line, ev_size in events:
                if batch and (size + ev_size > 1_000_000 or len(batch) >= min(int(c["max_batch_events"]), 10000)
                              or ms - batch[0]["timestamp"] > 23 * 3600 * 1000):
                    self.aws("logs", "put-log-events", input_json={"logGroupName": c["log_group"], "logStreamName": stream, "logEvents": batch})
                    sent += len(batch); batch, size = [], 0
                batch.append({"timestamp": ms, "message": line}); size += ev_size
            if batch:
                self.aws("logs", "put-log-events", input_json={"logGroupName": c["log_group"], "logStreamName": stream, "logEvents": batch})
                sent += len(batch)
            self._save_offset(state, f.name, offset + sent)
            shipped += sent
        self.log.log("services.audit.shipped", f"{shipped} record(s) → CloudWatch Logs", log_group=c["log_group"], records=shipped)
        return {"shipped": shipped, "backend": "aws"}

    def _save_offset(self, state, name, offset):
        if state:
            self.db.update("audit_shipping", state["_id"], offset=offset)
        else:
            self.db.put("audit_shipping", {"file": name, "offset": offset})

    # ------------------------------------------------------------ lineage → DataZone
    def emit_lineage(self, event: dict) -> dict:
        blob = json.dumps(event, ensure_ascii=False, separators=(",", ":"))
        if len(blob.encode("utf-8")) > 300_000:
            raise ValueError("OpenLineage event larger than the DataZone limit of 300000 bytes")
        doc = self.db.put(self.cfg["lineage"]["local"]["collection"], {"status": "pending", "event": event,
                          "job": event.get("job", {}).get("name"), "event_run_id": event.get("run", {}).get("runId")})
        return self._post_lineage(doc)

    def _post_lineage(self, doc):
        coll = self.cfg["lineage"]["local"]["collection"]
        res = self.resolve("lineage")
        if res["backend"] != "aws":
            self.log.log("lineage.stored", "lineage event stored locally", job=doc.get("job"), backend="local", reason=res["reason"], doc_id=doc["_id"])
            return {"backend": "local", "status": "pending", "id": doc["_id"]}
        with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False, encoding="utf-8") as t:
            json.dump(doc["event"], t)
        try:
            out = self.aws("datazone", "post-lineage-event", "--domain-identifier", self.cfg["lineage"]["datazone"]["domain_identifier"],
                           "--event", f"fileb://{t.name}", "--client-token", doc["_id"])
            self.db.update(coll, doc["_id"], status="sent", aws_response=out)
            self.log.log("lineage.posted", "lineage event posted to Amazon DataZone", job=doc.get("job"), backend="aws", doc_id=doc["_id"])
            return {"backend": "aws", "status": "sent", "id": doc["_id"]}
        except ServiceUnavailable as ex:
            self.db.update(coll, doc["_id"], status="pending", last_error=str(ex))
            self.log.log("lineage.post_failed", str(ex), "WARN", job=doc.get("job"), doc_id=doc["_id"])
            return {"backend": "local", "status": "pending", "id": doc["_id"]}
        finally:
            os.unlink(t.name)

    # ------------------------------------------------------------ guardrail → Bedrock
    def guardrail(self, text: str, kind: str = "text", source: str = "") -> list:
        """Local scan always; Bedrock ApplyGuardrail additionally when available (prompt attacks, sensitive info)."""
        findings = security.scan_text(text, kind, source)
        res = self.resolve("guardrail")
        if res["backend"] == "aws" and text.strip():
            c = self.cfg["guardrail"]["bedrock"]
            step = int(c["max_chars_per_call"])
            for start in range(0, len(text), step):
                chunk = text[start:start + step]
                if self._guardrail_chars + len(chunk) > int(c["max_chars_per_run"]):
                    findings.append({"rule": "SEC-13", "name": "guardrail-budget-exhausted", "severity": "info", "line": 0, "excerpt": "",
                                     "message": "Bedrock guardrail character budget for this run reached; local scan only", "source": source})
                    break
                self._guardrail_chars += len(chunk)
                try:
                    out = self.aws("bedrock-runtime", "apply-guardrail", input_json={
                        "guardrailIdentifier": c["guardrail_identifier"], "guardrailVersion": c.get("guardrail_version") or "DRAFT",
                        "source": "INPUT", "content": [{"text": {"text": chunk}}]})
                except ServiceUnavailable as ex:
                    self.log.log("guardrail.bedrock_failed", str(ex), "WARN", source=source)
                    break
                if out.get("action") == "GUARDRAIL_INTERVENED":
                    kinds = []
                    for a in out.get("assessments", []):
                        for f in (a.get("contentPolicy", {}) or {}).get("filters", []):
                            kinds.append(f"content:{f.get('type')}:{f.get('confidence')}")
                        for f in (a.get("sensitiveInformationPolicy", {}) or {}).get("piiEntities", []):
                            kinds.append(f"pii:{f.get('type')}")
                        for f in (a.get("sensitiveInformationPolicy", {}) or {}).get("regexes", []):
                            kinds.append(f"regex:{f.get('name')}")
                        for f in (a.get("topicPolicy", {}) or {}).get("topics", []):
                            kinds.append(f"topic:{f.get('name')}")
                    findings.append({"rule": "SEC-13", "name": "bedrock-guardrail-intervened", "severity": "high",
                                     "line": text.count("\n", 0, start) + 1, "excerpt": ", ".join(kinds)[:200],
                                     "message": "Amazon Bedrock Guardrails intervened (prompt attack / sensitive information / denied topic)",
                                     "source": source})
        self.db.put("guardrail_results", {"source": source, "kind": kind, "backend": res["backend"],
                                          "findings": [{k: f[k] for k in ("rule", "name", "severity", "line")} for f in findings],
                                          "sha256": hashlib.sha256(text.encode("utf-8")).hexdigest()})
        return findings

    # ------------------------------------------------------------ archive → S3
    def archive(self, paths, label="artifacts") -> dict:
        rid = self.log.run_id
        files = []
        for p in paths:
            p = pathlib.Path(p)
            files += [x for x in sorted(p.rglob("*")) if x.is_file()] if p.is_dir() else [p]
        local_dir = self._path(self.cfg["archive"]["local"]["dir"]) / rid / label
        local_dir.mkdir(parents=True, exist_ok=True)
        manifest = {"run_id": rid, "created": now_rfc3339(), "files": []}
        for f in files:
            try:
                rel = f.resolve().relative_to(self.root)
            except ValueError:
                rel = pathlib.Path(f.name)
            dest = local_dir / rel
            dest.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(f, dest)
            manifest["files"].append({"path": str(rel), "sha256": sha256_file(f), "bytes": f.stat().st_size, "s3": None})
        res = self.resolve("archive")
        if res["backend"] == "aws":
            c = self.cfg["archive"]["s3"]
            until = (dt.datetime.now(dt.timezone.utc) + dt.timedelta(days=int(c["retention_days"]))).strftime("%Y-%m-%dT%H:%M:%SZ")
            for m in manifest["files"]:
                key = f"{c['prefix']}{rid}/{label}/{m['path']}"
                args = ["s3api", "put-object", "--bucket", c["bucket"], "--key", key, "--body", str(local_dir / m["path"]),
                        "--checksum-algorithm", "SHA256", "--metadata", f"run-id={rid},sha256={m['sha256']}"]
                if c.get("sse"):
                    args += ["--server-side-encryption", c["sse"]]
                    if c.get("kms_key_id") and c["sse"] == "aws:kms":
                        args += ["--ssekms-key-id", c["kms_key_id"]]
                if c.get("object_lock_mode"):
                    args += ["--object-lock-mode", c["object_lock_mode"], "--object-lock-retain-until-date", until]
                try:
                    self.aws(*args, timeout=60)
                    m["s3"] = f"s3://{c['bucket']}/{key}"
                except ServiceUnavailable as ex:
                    self.log.log("archive.s3_failed", str(ex), "WARN", file=m["path"])
        (local_dir / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
        pending = [m["path"] for m in manifest["files"] if not m["s3"]]
        self.db.put("archives", {"label": label, "local_dir": str(local_dir), "files": len(files),
                                 "status": "sent" if not pending else "pending", "backend": res["backend"]})
        self.log.log("archive.created", f"{len(files)} file(s) archived", label=label, backend=res["backend"], files=len(files),
                     pending_s3=len(pending), manifest=str(local_dir / "manifest.json"))
        return {"backend": res["backend"], "files": len(files), "pending": len(pending), "manifest": str(local_dir / "manifest.json")}

    # ------------------------------------------------------------ secrets → Secrets Manager
    def db_env(self) -> dict:
        """Environment additions carrying DB credentials (never logged). Local: nothing (PGPASSWORD / IAM token as before)."""
        res = self.resolve("secrets")
        if res["backend"] != "aws":
            return {}
        out = self.aws("secretsmanager", "get-secret-value", "--secret-id", self.cfg["secrets"]["secretsmanager"]["secret_id"],
                       "--query", "SecretString", capture_secret=True)
        try:
            sec = json.loads(out) if isinstance(out, str) else out
        except ValueError:
            sec = {}
        env = {}
        if isinstance(sec, dict):
            for src, dst in (("username", "PGUSER"), ("password", "PGPASSWORD"), ("host", "PGHOST"), ("port", "PGPORT"), ("dbname", "PGDATABASE")):
                if sec.get(src) not in (None, ""):
                    env[dst] = str(sec[src])
        self.log.log("secrets.fetched", "DB credentials fetched from AWS Secrets Manager", keys=sorted(k for k in env if k != "PGPASSWORD"),
                     password_present="PGPASSWORD" in env)
        return env

    # ------------------------------------------------------------ outbox
    def sync(self) -> dict:
        result = {"audit": None, "lineage": {"sent": 0, "pending": 0}}
        try:
            result["audit"] = self.ship_audit()
        except ServiceUnavailable as ex:
            result["audit"] = {"error": str(ex)}
            self.log.log("services.audit.ship_failed", str(ex), "WARN")
        pending = self.db.find(self.cfg["lineage"]["local"]["collection"], status="pending")
        if pending and self.resolve("lineage")["backend"] != "aws":
            result["lineage"]["pending"] = len(pending)          # nothing to send to; already recorded as lineage.stored
            return result
        for doc in pending:
            r = self._post_lineage(doc)
            result["lineage"]["sent" if r["status"] == "sent" else "pending"] += 1
        return result

    def status(self, refresh=False) -> list:
        rows = []
        for c in CONCERNS:
            try:
                r = self.resolve(c, refresh=refresh)
                rows.append((c, self.cfg[c]["backend"], r["backend"], r["reason"]))
            except ServiceUnavailable as ex:
                rows.append((c, self.cfg[c]["backend"], "UNAVAILABLE", str(ex)))
        return rows


def main(argv=None):
    utf8_stdio()
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("status"); p = sub.add_parser("probe"); p.add_argument("--refresh", action="store_true")
    sub.add_parser("sync"); sub.add_parser("show-config")
    p = sub.add_parser("lineage-emit"); p.add_argument("event")
    p = sub.add_parser("guardrail"); p.add_argument("paths", nargs="+"); p.add_argument("--json", action="store_true"); p.add_argument("--fail-on", default="high")
    p = sub.add_parser("archive"); p.add_argument("paths", nargs="+"); p.add_argument("--label", default="artifacts")
    p = sub.add_parser("exec"); p.add_argument("command", nargs=argparse.REMAINDER)
    a = ap.parse_args(argv)
    svc = Services()
    if a.cmd in ("status", "probe"):
        rows = svc.status(refresh=getattr(a, "refresh", False))
        print(f"config: {svc.cfg['_source']}")
        print(f"{'concern':<10} {'setting':<8} {'active':<12} reason")
        for r in rows:
            print(f"{r[0]:<10} {r[1]:<8} {r[2]:<12} {r[3]}")
        return 1 if any(r[2] == "UNAVAILABLE" for r in rows) else 0
    if a.cmd == "show-config":
        print(json.dumps(redact({k: v for k, v in svc.cfg.items()}), indent=2)); return 0
    if a.cmd == "sync":
        print(json.dumps(svc.sync(), indent=2)); return 0
    if a.cmd == "lineage-emit":
        print(json.dumps(svc.emit_lineage(json.loads(pathlib.Path(a.event).read_text(encoding="utf-8"))))); return 0
    if a.cmd == "guardrail":
        findings = []
        for p in a.paths:
            f = pathlib.Path(p)
            findings += security.check_size(f) or svc.guardrail(f.read_text(encoding="utf-8", errors="replace"), security.kind_for(f), str(f))
        security._print(findings, a.json)
        return 1 if security.at_or_above(findings, a.fail_on) else 0
    if a.cmd == "archive":
        print(json.dumps(svc.archive(a.paths, a.label))); return 0
    if a.cmd == "exec":
        cmdv = a.command[1:] if a.command[:1] == ["--"] else a.command
        if not cmdv:
            ap.error("exec needs a command")
        env = svc.log.child_env()
        env.update(svc.db_env())
        svc.log.log("services.exec", "running command with injected DB credentials", program=pathlib.Path(cmdv[0]).name)
        return subprocess.call(cmdv, env=env)


if __name__ == "__main__":
    try:
        sys.exit(main())
    except ServiceUnavailable as ex:
        print(f"ERROR: {ex}", file=sys.stderr); sys.exit(3)
