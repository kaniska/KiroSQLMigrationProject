#!/usr/bin/env python3
"""
migkit.localdb — a tiny local JSON document store (the offline fallback for AWS services).

Layout: <root>/<collection>.jsonl — one JSON document per line, append-only, file-locked.
Every document gets: _id (uuid hex), _ts (RFC 3339 UTC), _run_id (correlation), and the caller's fields.
Updates append a new version with the same _id; reads return the latest version per _id
(tombstones have _deleted=true). Used for: lineage events, migration state, guardrail results,
backend probe cache, and the AWS outbox (events waiting to be shipped).

  from migkit.localdb import LocalStore
  db = LocalStore("logs/state")
  doc = db.put("outbox", {"target": "cloudwatch", "payload": {...}})
  db.find("outbox", status="pending")
  db.update("outbox", doc["_id"], status="sent")
"""
import json
import os
import pathlib
import re
import uuid

try:
    from .platform_compat import file_lock  # type: ignore
except ImportError:  # executed as a script
    import sys
    sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent.parent))
    from migkit.platform_compat import file_lock  # type: ignore

_NAME = re.compile(r"^[a-z][a-z0-9_-]{0,63}$")


def _now():
    import datetime as dt
    t = dt.datetime.now(dt.timezone.utc)
    return t.strftime("%Y-%m-%dT%H:%M:%S.") + f"{t.microsecond // 1000:03d}Z"


class LocalStore:
    def __init__(self, root):
        self.root = pathlib.Path(root)

    def _file(self, collection: str) -> pathlib.Path:
        if not _NAME.match(collection):
            raise ValueError(f"invalid collection name {collection!r}")
        return self.root / f"{collection}.jsonl"

    def _append(self, collection: str, doc: dict) -> dict:
        self.root.mkdir(parents=True, exist_ok=True)
        p = self._file(collection)
        line = (json.dumps(doc, ensure_ascii=False, separators=(",", ":"), default=str) + "\n").encode("utf-8")
        with file_lock(p):
            with open(p, "ab") as f:
                f.write(line); f.flush(); os.fsync(f.fileno())
        return doc

    def put(self, collection: str, doc: dict) -> dict:
        d = {"_id": uuid.uuid4().hex, "_ts": _now(), "_run_id": os.environ.get("MIGRATION_RUN_ID", "")}
        d.update(doc)
        return self._append(collection, d)

    def update(self, collection: str, _id: str, **fields) -> dict:
        cur = self.get(collection, _id)
        if cur is None:
            raise KeyError(_id)
        cur.update(fields); cur["_ts"] = _now()
        return self._append(collection, cur)

    def delete(self, collection: str, _id: str):
        return self._append(collection, {"_id": _id, "_ts": _now(), "_deleted": True})

    def all(self, collection: str) -> list:
        p = self._file(collection)
        if not p.exists():
            return []
        latest = {}
        with open(p, encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                try:
                    d = json.loads(line)
                except ValueError:
                    continue                       # a torn last line never breaks reads
                latest[d.get("_id")] = d
        return [d for d in latest.values() if not d.get("_deleted")]

    def get(self, collection: str, _id: str):
        return next((d for d in self.all(collection) if d.get("_id") == _id), None)

    def find(self, collection: str, **equals) -> list:
        return [d for d in self.all(collection) if all(d.get(k) == v for k, v in equals.items())]

    def compact(self, collection: str) -> int:
        """Rewrite a collection keeping only the latest version of each live document."""
        docs = self.all(collection)
        p = self._file(collection); tmp = p.with_suffix(".jsonl.tmp")
        with file_lock(p):
            with open(tmp, "w", encoding="utf-8", newline="\n") as f:
                for d in docs:
                    f.write(json.dumps(d, ensure_ascii=False, separators=(",", ":"), default=str) + "\n")
            os.replace(tmp, p)
        return len(docs)
