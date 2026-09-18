#!/usr/bin/env python3
"""
Generate the Windows twins (<agent>-windows.json) of every agent listed in AGENTS: sql-migration-agent, sql-reporting-agent.

The two agents are identical in tools, resources, write paths, MCP servers and hooks; only the commands
differ: 'python3 x.py' -> 'python -X utf8 x.py', 'bash x.sh' -> 'x.cmd' (PowerShell launcher), and path
separators may be '\\' or '/'. Run after every change to the main agent:

  python3 supporting-files/make_windows_agent.py          (write)
  python3 supporting-files/make_windows_agent.py --check  (exit 1 when the Windows agent is out of date)
"""
import copy
import json
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
AGENTS = ["sql-migration-agent", "sql-reporting-agent"]
SRC = ROOT / ".kiro" / "agents" / "sql-migration-agent.json"          # kept for callers that import SRC/DST
DST = ROOT / ".kiro" / "agents" / "sql-migration-agent-windows.json"
SEP = r"[\\/]"


def win_regex(rx: str) -> str:
    """allowedCommands regex: bash .sh -> .cmd launcher or powershell -File .ps1; python3 -> python/py; any separator."""
    m = re.match(r"^bash (.+)\\\.sh(.*)$", rx)
    if m:
        path = m.group(1).replace("/", SEP)
        return (rf"({path}\.cmd|powershell(\.exe)? -NoProfile -ExecutionPolicy Bypass -File {path}\.ps1)" + m.group(2))
    m = re.match(r"^python3 (.+)$", rx)
    if m:
        rest = m.group(1)
        head, _, tail = rest.partition(" ")
        return r"(python|py -3|python3)( -X utf8)? " + head.replace("/", SEP) + (" " + tail.replace("bash supporting-files/run_tests\\.sh", r"supporting-files[\\/]run_tests\.cmd") if tail else "")
    return rx


def win_glob(g: str) -> list:
    """permissions shell match globs."""
    m = re.match(r"^bash (.+)\.sh(\*?)$", g)
    if m:
        p = m.group(1)
        return [f"{p}.cmd{m.group(2)}", f"{p.replace('/', chr(92))}.cmd{m.group(2)}",
                f"powershell -NoProfile -ExecutionPolicy Bypass -File {p}.ps1{m.group(2)}"]
    m = re.match(r"^python3 (.+)$", g)
    if m:
        return [f"python {m.group(1)}", f"python -X utf8 {m.group(1)}", f"py -3 {m.group(1)}", f"python {m.group(1).replace('/', chr(92))}"]
    return [g]


def build(src: pathlib.Path = SRC) -> dict:
    a = json.loads(src.read_text(encoding="utf-8"))
    w = copy.deepcopy(a)
    w["name"] = a["name"] + "-windows"
    w["description"] = a["description"].rstrip(".") + ". Windows variant: PowerShell/.cmd launchers and python instead of bash/python3."
    w["welcomeMessage"] = a.get("welcomeMessage", "") + " (Windows)"
    ts = w.get("toolsSettings", {}).get("execute_bash", {})
    if "allowedCommands" in ts:
        ts["allowedCommands"] = [win_regex(r) for r in a["toolsSettings"]["execute_bash"]["allowedCommands"]]
    for rule in w.get("permissions", {}).get("rules", []):
        if rule.get("capability") == "shell":
            rule["match"] = [x for g in rule["match"] for x in win_glob(g)]
    for event, entries in w.get("hooks", {}).items():
        for e in entries:
            e["command"] = re.sub(r"^python3 ", "python -X utf8 ", e["command"])
    return w


def render(w: dict) -> str:
    return json.dumps(w, indent=2, ensure_ascii=False) + "\n"


if __name__ == "__main__":
    stale = []
    for name in AGENTS:
        src = ROOT / ".kiro" / "agents" / f"{name}.json"; dst = ROOT / ".kiro" / "agents" / f"{name}-windows.json"
        text = render(build(src))
        if "--check" in sys.argv:
            if (dst.read_text(encoding="utf-8") if dst.exists() else "") != text:
                stale.append(str(dst))
        else:
            dst.write_text(text, encoding="utf-8"); print(f"wrote {dst}")
    if "--check" in sys.argv:
        if stale:
            print("out of date: " + ", ".join(stale) + " — run python3 supporting-files/make_windows_agent.py", file=sys.stderr); sys.exit(1)
        print("windows agents up to date")
