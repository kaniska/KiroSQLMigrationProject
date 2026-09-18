#!/usr/bin/env python3
"""
preToolUse guardrail for the sql-migration-agent (Kiro CLI hook).

Deterministic controls outside the model: whatever an injected instruction in a source file convinces
the agent to try, these calls are refused. Exit code 2 blocks the tool call and returns the reason on
stderr to the agent; exit 0 allows it. Every decision is written to the audit log with the session's
correlation id. Rules are catalogued as GRD-nn in
.kiro/skills/sql-conversion/references/security-logging.md.
"""
import os
import pathlib
import re
import shlex
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
from _common import ROOT, read_event, logger, summarize_input, security, utf8_stdio  # noqa: E402

TEST_DB = re.compile(r"(test|dev|sandbox|local)", re.I)
SHELL_RULES = [
    ("GRD-01", "credential access", r"(~|\$HOME|/Users/[^/\s]+|/home/[^/\s]+)/\.aws\b|\.aws/(credentials|config)\b|\baws\s+configure\s+(get|export-credentials)\b|\baws\s+configure\s+export-credentials\b|\bprintenv\b|(^|[;&|]\s*)env\s*($|[;&|])|\bset\s*($|\|)|\becho\s+[^\n]*\$\{?(AWS_SECRET|AWS_SESSION_TOKEN|PGPASSWORD|MIGRATION_TOKEN)|\bsecurity\s+find-(generic|internet)-password\b|169\.254\.169\.254|\bsecretsmanager\s+get-secret-value\b|\bcat\s+[^\n]*(\.pem|id_rsa|id_ed25519|\.env)\b"),
    ("GRD-02", "remote code execution or data exfiltration", r"\b(curl|wget)\b[^\n|]*\|\s*(sudo\s+)?(sh|bash|zsh|python3?|perl|ruby|node)\b|\b(curl|wget)\b[^\n]*\s(-d|--data(-binary|-raw|-urlencode)?|-F|--form|-T|--upload-file|--post-(data|file))\b|\b(nc|ncat|netcat|telnet|socat)\s|\b(scp|sftp)\s|\brsync\s[^\n]*\s([\w.-]+@)?[\w.-]+:|\bssh\s+[\w.-]+@|\bbase64\s+(-d|--decode)\b[^\n]*\|\s*(sh|bash|python3?)"),
    ("GRD-03", "destructive or irreversible command", r"\brm\s+(-[a-zA-Z]*[rf][a-zA-Z]*\s+)+(/|~|\$HOME|\.|\*|\.kiro|logs|source|generated|tests)(\s|/?$|/\*|/\s)|\bgit\s+(push|reset\s+--hard|clean\s+-[a-z]*f|filter-branch|rebase)\b|\bchmod\s+(-R\s+)?[0-7]*7[0-7]{2}\b|\bsudo\b|\bmkfs\b|\bdd\s+if=|:\(\)\s*\{"),
    ("GRD-04", "tampering with guardrails, configuration or audit logs", r"(>{1,2}|\btee\b|\bsed\s+-i|\bperl\s+-[a-z]*i|\bmv\b|\bcp\b|\brm\b|\btruncate\b|\bchmod\b|\bln\b|\btouch\b)[^\n;|&]*(\.kiro/(steering|agents|skills|settings|hooks)|logs/audit|logs/state/current_session\.json)|\bunset\s+MIGRATION_|\bexport\s+MIGRATION_(OFFLINE|[A-Z]+_BACKEND|LOG_DIR|INHERIT_SESSION)\b|\bMIGRATION_(OFFLINE|[A-Z]+_BACKEND|LOG_DIR)=|\bPGTEST_ALLOW_(SUPERUSER|DANGEROUS)="),
    ("GRD-05", "AWS resource change (the agent may only read AWS)", r"\baws\s+(--[a-z-]+\s+\S+\s+)*[a-z0-9-]+\s+(delete|remove|put|create|modify|update|terminate|stop|start|reboot|attach|detach|authorize|revoke|tag|untag|restore|reset|disable|enable|deregister|register|associate|disassociate|import|copy|replace|set|send|invoke|run|execute|cancel|purge|rotate|post|batch|upload|accept|reject)-[a-z0-9-]+|\baws\s+s3\s+(cp|mv|rm|sync|rb|mb)\b"),
    ("GRD-07", "software installation (ask the user)", r"\b(pip3?|pipx|uv)\s+(install|add)\b|\bnpm\s+(i|install)\b|\bbrew\s+(install|upgrade|tap)\b|\bapt(-get)?\s+install\b|\bgem\s+install\b"),
    ("GRD-08", "running agents with every tool trusted", r"\bkiro-cli\b[^\n]*\s(-a|--trust-all-tools)\b|\b/tools\s+trust-all\b"),
]
# Windows: PowerShell and cmd.exe forms of the same rules (commands are matched after '\' → '/')
WINDOWS_SHELL_RULES = [
    ("GRD-01", "credential access", r"(%USERPROFILE%|\$env:USERPROFILE|\$HOME|[A-Za-z]:/Users/[^/\s]+)/\.aws\b|\$env:(AWS_SECRET_ACCESS_KEY|AWS_SESSION_TOKEN|PGPASSWORD|MIGRATION_TOKEN)\b|\b(gci|dir|ls|Get-ChildItem|Get-Item)\s+env:|\b(type|Get-Content|gc)\s+[^\n]*(\.pem|id_rsa|id_ed25519|\.env|\.pgpass)\b|\bcmdkey\s+/list\b|\bvaultcmd\b|\bGet-StoredCredential\b|\bGet-SECSecretValue\b"),
    ("GRD-02", "remote code execution or data exfiltration", r"\b(iwr|irm|Invoke-WebRequest|Invoke-RestMethod|curl\.exe|wget\.exe)\b[^\n]*\|\s*(iex|Invoke-Expression|powershell|pwsh|cmd)\b|\b(iex|Invoke-Expression)\b[^\n]*(DownloadString|iwr|irm|Invoke-WebRequest|Invoke-RestMethod)|\bInvoke-(WebRequest|RestMethod)\b[^\n]*(-Method\s+(Post|Put|Patch)|-InFile|-Body)|\bbitsadmin\b|\bcertutil\b[^\n]*-urlcache|\bStart-BitsTransfer\b|\b(powershell|pwsh)(\.exe)?\b[^\n]*\s-(e|ec|enc|encodedcommand)\s"),
    ("GRD-03", "destructive or irreversible command", r"\b(Remove-Item|ri|rd|rmdir|del|erase)\b[^\n]*(-Recurse|\s/s\b)[^\n]*\s(/|~|\.|\*|\.kiro|logs|source|generated|tests|[A-Za-z]:/?)(\s|/?$|/\*|/\s)|\b(Remove-Item|ri|rd|rmdir|del|erase)\s+(/|~|\.|\*|\.kiro|logs|source|generated|tests|[A-Za-z]:/?)(\s|/\s|/\*)[^\n]*(-Recurse|/s\b)|\bFormat-Volume\b|\bClear-Disk\b|\bformat\s+[A-Za-z]:|\bStart-Process\b[^\n]*-Verb\s+RunAs|\brunas\s|\bicacls\b[^\n]*/grant[^\n]*Everyone"),
    ("GRD-04", "tampering with guardrails, configuration or audit logs", r"\b(Set-Content|Add-Content|Out-File|Clear-Content|Remove-Item|Move-Item|Copy-Item|Rename-Item|New-Item|sc|ac|del|erase|move|copy|ren|attrib)\b[^\n;|&]*(\.kiro/(steering|agents|skills|settings|hooks)|logs/audit|logs/state/current_session\.json)|\$env:(MIGRATION_(OFFLINE|[A-Z]+_BACKEND|LOG_DIR|INHERIT_SESSION|RUN_ID)|PGTEST_ALLOW_(SUPERUSER|DANGEROUS))\s*=|\b(Remove-Item|ri)\s+env:(MIGRATION_|PGTEST_)|\bsetx\s+(MIGRATION_|PGTEST_ALLOW_)"),
    ("GRD-05", "AWS resource change (the agent may only read AWS)", r"\baws\.exe\s+(--[a-z-]+\s+\S+\s+)*[a-z0-9-]+\s+(delete|remove|put|create|modify|update|terminate|stop|start|reboot|attach|detach|authorize|revoke|tag|untag|restore|reset|disable|enable|deregister|register|associate|disassociate|import|copy|replace|set|send|invoke|run|execute|cancel|purge|rotate|post|batch|upload|accept|reject)-[a-z0-9-]+|\b(New|Remove|Set|Update|Write|Publish|Start|Stop)-(RDS|S3|CWL|IAM|SEC|DZ|BDR|KMS|CT|EC2)[A-Za-z]*\b"),
    ("GRD-07", "software installation (ask the user)", r"\b(winget|choco|scoop)\s+(install|upgrade)\b|\bInstall-(Module|Package|Script)\b|\b(py|python3?)(\.exe)?\s+(-3\s+)?-m\s+pip\s+install\b"),
]
SHELL_RES = [(r, why, re.compile(p, re.I)) for r, why, p in SHELL_RULES + WINDOWS_SHELL_RULES]
SHELL_TOOLS = ("execute_bash", "shell", "execute_cmd", "bash", "execute_powershell", "powershell", "execute_command", "run_command", "cmd")
READ_DENY = re.compile(r"(^|/)\.aws/|(^|/)\.ssh/|(^|/)\.env(\.|$)|\.pem$|id_(rsa|ed25519)|(^|/)\.netrc$|(^|/)\.pgpass$|kiro-cli/data\.sqlite3|/\.kiro/sessions/", re.I)
WRITE_DENY = re.compile(r"(^|/)\.kiro/(steering|agents|skills|settings|hooks)(/|$)|(^|/)logs/(audit|state)(/|$)|(^|/)\.git/", re.I)


TOOL_DB = re.compile(r"\b(redshift_tool|iceberg_tool|schema_tool)\.py\b[^\n|;&]*?\s--database[= ]([\w.-]+)", re.I)


def psql_databases(cmd: str):
    dbs = []
    for m in re.finditer(r"\bdbname=([\w.-]+)|\bPGDATABASE\s*=\s*['\"]?([\w.-]+)|\bpsql(?:\.exe)?\b[^\n|;&]*?\s(-d|--dbname)[= ]([\w.-]+)", cmd):
        dbs.append(next(g for g in (m.group(1), m.group(2), m.group(4)) if g))
    for m in re.finditer(r"postgres(ql)?://[^\s/]+/([\w.-]+)", cmd):
        dbs.append(m.group(2))
    return dbs


def check_shell(cmd: str):
    cmd = cmd.replace("\\", "/")                      # Windows paths: .kiro\steering → .kiro/steering
    for rule, why, rx in SHELL_RES:
        m = rx.search(cmd)
        if m:
            return rule, f"{why}: '{m.group(0)[:80]}'"
    aws_read_only = re.search(r"\baws\b", cmd)
    if aws_read_only and re.search(r"\baws(\.exe)?\s+(--[a-z-]+\s+\S+\s+)*secretsmanager\b", cmd, re.I):
        return "GRD-01", "reading secrets directly — use 'services.py exec -- <command>' which injects credentials without showing them"
    if re.search(r"\bpsql(\.exe)?\b", cmd, re.I):
        for db in psql_databases(cmd):
            if not TEST_DB.search(db):
                return "GRD-06", f"psql against database '{db}' — only databases whose name contains test/dev/sandbox/local"
        unquoted = re.sub(r"[\'\"]", " ", cmd)                     # SQL passed with -c '…' is inside shell quotes
        crit = [f for f in security.scan_text(unquoted, "sql") if f["rule"] == "SEC-04" and f["severity"] == "critical"]
        if crit:
            return "GRD-06", f"psql with dangerous SQL ({crit[0]['name']}): {crit[0]['message']}"
    for m in TOOL_DB.finditer(cmd):                              # skill tools that reach Redshift / Athena / Glue
        if not TEST_DB.search(m.group(2)):
            return "GRD-06", f"{m.group(1)}.py against database '{m.group(2)}' — only databases whose name contains test/dev/sandbox/local"
    if re.search(r"\bchange_tool\.py\b[^\n|;&]*\s--apply\b", cmd, re.I):
        return "GRD-12", "applying change patches to a live target — the tool only produces dry-run packages; deploy reviewed packages through the normal path"
    return None


def check_write(path: str, content: str):
    path = (path or "").replace("\\", "/")
    if path:
        p = pathlib.Path(path)
        abs_p = (p if p.is_absolute() else ROOT / p).resolve()
        try:
            rel = abs_p.relative_to(ROOT)
        except ValueError:
            return "GRD-09", f"write outside the workspace: {path}"
        if WRITE_DENY.search(rel.as_posix()):
            return "GRD-04", f"write to protected path {rel} (guardrails, configuration, audit logs)"
    if content:
        found = security.scan_text(content, "sql" if str(path).endswith(".sql") else "text", str(path))
        for rule, sev in (("SEC-03", None), ("SEC-02", None), ("SEC-01", None)):
            hit = [f for f in found if f["rule"] == rule]
            if hit:
                return f"GRD-10", f"{hit[0]['rule']} {hit[0]['name']} in content for {path}: {hit[0]['message']}"
        crit = [f for f in found if f["rule"] == "SEC-04" and f["severity"] == "critical"]
        if crit and not str(path).startswith(("tests/", "docs/")) and "/references/" not in str(path):
            return "GRD-11", (f"dangerous PostgreSQL ({crit[0]['name']}) written to {path}: never introduce it by conversion; "
                              "flag the source construct with a TODO and ask the user")
    return None


def decide(ev: dict):
    tool = str(ev.get("tool_name", ""))
    ti = ev.get("tool_input") or {}
    if not isinstance(ti, dict):
        ti = {"value": ti}
    t = tool.lower()
    if t in SHELL_TOOLS:
        return check_shell(str(ti.get("command", ti.get("value", ""))))
    if t in ("fs_write", "write"):
        content = "".join(str(ti.get(k, "")) for k in ("file_text", "new_str", "content", "text"))
        return check_write(str(ti.get("path", "")), content)
    if t in ("fs_read", "read"):
        paths = [str(ti.get("path", ""))] + [str(op.get("path", "")) for op in ti.get("operations", []) if isinstance(op, dict)]
        for p in paths:
            if p and READ_DENY.search(p.replace("\\", "/")):
                return "GRD-01", f"reading a credential store: {p}"
        return None
    if t.startswith("@") or "/" in t:
        sql = " ".join(str(v) for v in ti.values() if isinstance(v, str))
        crit = [f for f in security.scan_text(sql, "sql") if f["rule"] == "SEC-04" and f["severity"] == "critical"]
        if crit:
            return "GRD-06", f"MCP call with dangerous SQL ({crit[0]['name']})"
        if re.search(r"(?i)(allow_write_query|--allow-write|allow-write-query)", sql):
            return "GRD-05", "MCP write mode requested"
    return None


def main():
    utf8_stdio()
    ev = read_event()
    log = logger("kiro.hook.guard")
    verdict = decide(ev)
    attrs = {"tool_name": ev.get("tool_name"), "session_id": ev.get("session_id"), "cwd": ev.get("cwd"),
             "tool_input": summarize_input(ev.get("tool_input"))}
    if verdict:
        rule, reason = verdict
        log.log("guard.blocked", reason, "WARN", rule=rule, **attrs)
        print(f"BLOCKED by guardrail {rule}: {reason}. If this is really needed, stop and ask the user to run it.", file=sys.stderr)
        return 2
    log.log("guard.allowed", "", "INFO", **attrs)
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as ex:  # fail closed: a broken guard must not silently allow everything
        print(f"BLOCKED: guardrail hook error ({type(ex).__name__}: {ex})", file=sys.stderr)
        sys.exit(2)
