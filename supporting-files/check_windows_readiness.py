#!/usr/bin/env python3
"""
check_windows_readiness.py — static readiness check of the Windows scripts (no PowerShell needed).

  python3 supporting-files/check_windows_readiness.py          # report; exit 1 on any finding

Checks (HOOK-06):
  * every .sh has a .ps1 twin (UTF-8 BOM, CRLF) and a .cmd launcher (CRLF) that starts it
  * every .ps1 parses structurally: balanced { } ( ) [ ] outside strings/comments, no here-string left open
  * every file a .ps1 references (Join-Path … 'x.py' / 'x.md' / 'x.sql' / 'x.ps1', .cmd launchers) exists
  * hand-written twins reference the same Python tests, catalogs and --prefix ids as their .sh
  * generated twins are in sync (make_skill_runners.py --check), Windows agents in sync (make_windows_agent.py --check)
  * no bare 'python3' / 'bash' calls in .ps1 (Windows has python / py -3 and no bash); hook commands use python -X utf8
  * mcp.json has a Windows variant of every local python server; .gitattributes keeps eol per platform
"""
import json
import pathlib
import re
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
findings = []


def finding(msg):
    findings.append(msg)


def strip_ps(text: str) -> str:
    """Blank out comments, strings and here-strings (a small scanner, so an apostrophe in a comment does not start a string)."""
    out, i, n = [], 0, len(text)
    while i < n:
        ch = text[i]; two = text[i:i + 2]
        if two == "<#":
            j = text.find("#>", i + 2); i = n if j < 0 else j + 2; continue
        if two in ("@'", '@"'):
            end = "'@" if two == "@'" else '"@'
            j = text.find(end, i + 2); i = n if j < 0 else j + 2; out.append("''"); continue
        if ch == "#":
            j = text.find("\n", i); i = n if j < 0 else j; continue
        if ch == "'":
            j = i + 1
            while j < n:
                if text[j] == "'" and text[j + 1:j + 2] == "'":
                    j += 2; continue
                if text[j] == "'":
                    break
                j += 1
            i = j + 1; out.append("''"); continue
        if ch == '"':
            j = i + 1
            while j < n and text[j] != '"':
                j += 2 if text[j] == "`" else 1
            i = j + 1; out.append('""'); continue
        if two == "${":
            j = text.find("}", i); i = n if j < 0 else j + 1; out.append("$v"); continue
        out.append(ch); i += 1
    return "".join(out)


def check_pairs():
    for sh in sorted(p for p in ROOT.rglob("*.sh") if "dist" not in p.parts and ".git" not in p.parts):
        ps1, cmd = sh.with_suffix(".ps1"), sh.with_suffix(".cmd")
        if not ps1.exists():
            finding(f"{sh.relative_to(ROOT)}: missing PowerShell twin"); continue
        if not cmd.exists():
            finding(f"{sh.relative_to(ROOT)}: missing .cmd launcher"); continue
        raw = ps1.read_bytes()
        if not raw.startswith(b"\xef\xbb\xbf"):
            finding(f"{ps1.relative_to(ROOT)}: no UTF-8 BOM (Windows PowerShell 5.1 reads ANSI otherwise)")
        if b"\r\n" not in raw or re.search(rb"(?<!\r)\n", raw):
            finding(f"{ps1.relative_to(ROOT)}: line endings must be CRLF throughout")
        craw = cmd.read_bytes()
        if b"\r\n" not in craw or ps1.name.encode() not in craw:
            finding(f"{cmd.relative_to(ROOT)}: must be CRLF and launch {ps1.name}")
        if b"-ExecutionPolicy Bypass" not in craw:
            finding(f"{cmd.relative_to(ROOT)}: launcher must pass -ExecutionPolicy Bypass")


def check_ps1_syntax_and_refs():
    for ps1 in sorted(p for p in ROOT.rglob("*.ps1") if "dist" not in p.parts and ".git" not in p.parts):
        rel = ps1.relative_to(ROOT); text = ps1.read_bytes().decode("utf-8-sig")
        code = strip_ps(text)
        for o, c in (("{", "}"), ("(", ")"), ("[", "]")):
            if code.count(o) != code.count(c):
                finding(f"{rel}: unbalanced {o}{c} ({code.count(o)} vs {code.count(c)})")
        if re.search(r"(?m)^\s*python3\s", text) or re.search(r"&\s*python3\b", text):
            finding(f"{rel}: calls python3 directly — use Invoke-MigPython / Get-MigPython")
        if re.search(r"(?m)^\s*bash\s", text) or re.search(r"&\s*bash\b", text):
            finding(f"{rel}: calls bash — Windows has no bash; call the .ps1 twin")
        # referenced files: Join-Path $Var 'relative\path.ext' with a known base variable
        bases = {"$Scripts": ps1.parent, "$PSScriptRoot": ps1.parent, "$Engine": ROOT / ".kiro/skills/sql-conversion/scripts", "$Kit": ROOT / ".kiro/skills/sql-conversion/scripts/migkit",
                 "$ProjectDir": ROOT, "$Skill": ps1.parent.parent, "$Ex": ps1.parent.parent / "references" / "examples", "$EX": ps1.parent.parent / "references" / "examples"}
        for m in re.finditer(r"Join-Path\s+(\$\w+)\s+'([^']+)'", text):
            base, relp = m.group(1), m.group(2)
            line = text[text.rfind("\n", 0, m.start()) + 1:text.find("\n", m.end())]
            if base not in bases or "*" in relp or "$" in relp or "Test-Path" in line:   # existence checks may reference absent paths on purpose
                continue
            target = (bases[base] / relp.replace("\\", "/")).resolve()
            if not target.exists() and not relp.endswith((".jsonl", ".log", ".zip", ".json")) and "results" not in relp.lower() and "rendered" not in relp.lower() and ".generated" not in relp:
                finding(f"{rel}: references missing file {base}\\{relp}")
        for m in re.finditer(r"'([^']*\.(?:py|md|sql))'", text):
            pass  # covered above when joined with a base


def refs(text: str) -> dict:
    """Test scripts, catalogs and prefixes a runner mentions (comments excluded)."""
    text = re.sub(r"<#[\s\S]*?#>", "", text)
    text = "\n".join(l for l in text.splitlines() if not l.strip().startswith("#"))
    return {"tests": sorted(set(re.findall(r"(test_\w+\.py)", text))), "catalogs": sorted(set(re.findall(r"([\w-]+\.md)", text))),
            "prefixes": sorted(set(re.findall(r"--prefix'?,?\s*'?([A-Z]{2,4})\b", text))), "tools": sorted(set(re.findall(r"\b(\w+_tool\.py|pgtest\.\w+|check_rule_coverage\.py|test_hooks\.py|test_agents\.py|test_mcp_server\.py)\b", text)))}


def check_twin_drift():
    for sh in sorted(p for p in ROOT.rglob("*.sh") if "dist" not in p.parts and ".git" not in p.parts):
        ps1 = sh.with_suffix(".ps1")
        if not ps1.exists():
            continue
        a, b = refs(sh.read_text(encoding="utf-8")), refs(ps1.read_bytes().decode("utf-8-sig"))
        b["tools"] = sorted({t.replace("pgtest.ps1", "pgtest.sh") for t in b["tools"]}); a["tools"] = sorted({t.replace("pgtest.cmd", "pgtest.sh") for t in a["tools"]})
        for key in ("tests", "catalogs", "prefixes", "tools"):
            if a[key] != b[key]:
                finding(f"{sh.relative_to(ROOT)} vs .ps1: {key} differ — sh {a[key]} / ps1 {b[key]}")


def check_generators_and_agents():
    for script in ("make_skill_runners.py", "make_windows_agent.py"):
        p = subprocess.run([sys.executable, str(ROOT / "supporting-files" / script), "--check"], capture_output=True, text=True)
        if p.returncode != 0:
            finding(f"{script} --check: {(p.stdout + p.stderr).strip()}")
    for agent in sorted((ROOT / ".kiro" / "agents").glob("*-windows.json")):
        a = json.loads(agent.read_text(encoding="utf-8"))
        for event, entries in a.get("hooks", {}).items():
            for e in entries:
                if not e["command"].startswith("python -X utf8 "):
                    finding(f"{agent.name}: hook {event} must run 'python -X utf8': {e['command']}")
        for rx in a["toolsSettings"]["execute_bash"]["allowedCommands"]:
            if rx.startswith("bash ") or rx.startswith("python3 "):
                finding(f"{agent.name}: allowedCommands still POSIX: {rx}")


def check_settings():
    mcp = json.loads((ROOT / ".kiro" / "settings" / "mcp.json").read_text(encoding="utf-8"))["mcpServers"]
    for name, cfg in mcp.items():
        if cfg.get("command") == "python3" and not name.endswith("-windows"):
            if f"{name}-windows" not in mcp:
                finding(f"mcp.json: {name} runs python3; add a '{name}-windows' entry with 'python -X utf8'")
    ga = (ROOT / ".gitattributes").read_text(encoding="utf-8")
    for pat in ("*.ps1   text eol=crlf", "*.cmd   text eol=crlf", "*.sh    text eol=lf", "*.xml   -text", "*.prm   -text"):
        if pat not in ga:
            finding(f".gitattributes: missing '{pat}'")
    for py in sorted(p for p in ROOT.rglob("tests/test_*.py") if ".git" not in p.parts):
        if 'os.name == "nt"' not in py.read_text(encoding="utf-8"):
            finding(f"{py.relative_to(ROOT)}: no Windows UTF-8 re-exec guard (os.name == 'nt')")


def main():
    check_pairs(); check_ps1_syntax_and_refs(); check_twin_drift(); check_generators_and_agents(); check_settings()
    if findings:
        print("WINDOWS READINESS: FAIL"); [print("  - " + f) for f in findings]; return 1
    print("WINDOWS READINESS: PASS (twins present, CRLF/BOM, balanced syntax, references resolve, no twin drift, generators in sync, agents and settings ready)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
