#!/usr/bin/env python3
"""
Package the workspace as a zip that includes the .kiro folder (steering, skills, agents, hooks, settings).

  python3 supporting-files/package.py [--out dist/SQLMigrationProject.zip] [--include-logs]

Why a script: on macOS and Linux a leading dot hides '.kiro' in file browsers, and some archivers skip
hidden entries. The folder must keep its name — Kiro only reads '.kiro'. This script
  1. clears hidden flags/attributes on .kiro (macOS: chflags nohidden; Windows: attrib -h -s),
  2. writes a zip with every file under the workspace, .kiro first, keeping bytes and line endings exactly,
     executable bits for *.sh, and forward-slash paths that unzip on Windows, Linux and macOS,
  3. verifies the archive contains the steering files, every SKILL.md and the agent configurations.
Excluded: logs/ (runtime evidence; add --include-logs), dist/, __pycache__/, .generated/, OS clutter.
"""
import argparse
import datetime as dt
import os
import pathlib
import shutil
import stat
import subprocess
import sys
import zipfile

ROOT = pathlib.Path(__file__).resolve().parent.parent
EXCLUDE_DIRS = {"__pycache__", ".generated", "dist", ".git", "node_modules", ".pytest_cache"}
EXCLUDE_FILES = {".DS_Store", "Thumbs.db", "desktop.ini"}
REQUIRED = [".kiro/steering/migration.md", ".kiro/steering/security.md", ".kiro/agents/sql-migration-agent.json",
            ".kiro/agents/sql-migration-agent-windows.json", ".kiro/skills/sql-conversion/SKILL.md",
            ".kiro/skills/sql-reporting/SKILL.md", ".kiro/skills/informatica-etl-conversion/SKILL.md",
            ".kiro/settings/mcp.json", "supporting-files/run_tests.sh", "supporting-files/run_tests.cmd"]


def unhide(path: pathlib.Path):
    """Remove OS-level hidden markers (the leading dot itself is required by Kiro and stays)."""
    try:
        if sys.platform == "darwin" and shutil.which("chflags"):
            subprocess.run(["chflags", "-R", "nohidden", str(path)], check=False)
        elif os.name == "nt":
            subprocess.run(["attrib", "-h", "-s", str(path)], check=False, shell=False)
            subprocess.run(["attrib", "-h", "-s", str(path / "*"), "/s", "/d"], check=False, shell=False)
    except OSError as ex:
        print(f"note: could not clear hidden attributes on {path}: {ex}")


def files_to_pack(include_logs: bool):
    out = []
    for dirpath, dirnames, filenames in os.walk(ROOT):
        rel_dir = pathlib.Path(dirpath).relative_to(ROOT)
        dirnames[:] = sorted(d for d in dirnames if d not in EXCLUDE_DIRS and not (rel_dir == pathlib.Path(".") and d == "logs" and not include_logs))
        for name in sorted(filenames):
            if name in EXCLUDE_FILES or name.endswith((".pyc", ".lock")) or name.startswith("~$"):
                continue
            p = pathlib.Path(dirpath) / name
            if p.is_symlink():
                continue
            out.append(p)
    out.sort(key=lambda p: (not p.relative_to(ROOT).as_posix().startswith(".kiro/"), p.relative_to(ROOT).as_posix()))
    return out


def main():
    if not (ROOT / ".kiro").is_dir():
        hint = " Rename it back: mv kiro .kiro (Windows: Rename-Item kiro .kiro)" if (ROOT / "kiro").is_dir() else ""
        print(f"ERROR: {ROOT / '.kiro'} not found. Kiro only loads a folder named exactly .kiro.{hint}", file=sys.stderr)
        return 2
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--out", default=None)
    ap.add_argument("--include-logs", action="store_true")
    a = ap.parse_args()
    for s in (sys.stdout, sys.stderr):
        try:
            s.reconfigure(encoding="utf-8", errors="replace")
        except (AttributeError, ValueError):
            pass
    unhide(ROOT / ".kiro")
    out = pathlib.Path(a.out) if a.out else ROOT / "dist" / f"{ROOT.name}-{dt.date.today():%Y%m%d}.zip"
    out = out if out.is_absolute() else (pathlib.Path.cwd() / out)
    out.parent.mkdir(parents=True, exist_ok=True)
    top = ROOT.name
    files = [f for f in files_to_pack(a.include_logs) if f.resolve() != out.resolve()]
    with zipfile.ZipFile(out, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=9) as z:
        for f in files:
            rel = f.relative_to(ROOT).as_posix()
            info = zipfile.ZipInfo.from_file(f, arcname=f"{top}/{rel}")
            executable = bool(f.stat().st_mode & 0o111) or f.suffix == ".sh"      # keep +x (e.g. the stub aws CLI); .sh always
            mode = 0o755 if executable else 0o644
            info.external_attr = (stat.S_IFREG | mode) << 16
            info.compress_type = zipfile.ZIP_DEFLATED
            with open(f, "rb") as fh:
                z.writestr(info, fh.read())
    with zipfile.ZipFile(out) as z:
        names = set(z.namelist())
    missing = [r for r in REQUIRED if f"{top}/{r}" not in names]
    kiro = sum(1 for n in names if n.startswith(f"{top}/.kiro/"))
    print(f"wrote {out}  ({len(names)} files, {kiro} under .kiro/, {out.stat().st_size // 1024} KB)")
    if missing:
        print("ERROR: missing from the archive: " + ", ".join(missing), file=sys.stderr)
        return 1
    print("verified: steering, skills, agents (macOS/Linux and Windows) and settings are inside .kiro/ in the zip")
    return 0


if __name__ == "__main__":
    sys.exit(main())
