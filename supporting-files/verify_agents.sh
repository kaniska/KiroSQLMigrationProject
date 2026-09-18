#!/usr/bin/env bash
# ============================================================
# Verify the Kiro agents (sql-migration-agent, sql-reporting-agent and their Windows twins)
#   1. structural tests (.kiro/agents/hooks/tests/test_agents.py, catalog AGENTS.md AG-nn)
#   2. kiro-cli agent validate + agent list (when kiro-cli is installed)
#   3. --smoke: one headless prompt per agent (needs a signed-in kiro-cli; read-only prompts)
# Usage: bash supporting-files/verify_agents.sh [--smoke]
# ============================================================
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_DIR"
[[ -d .kiro ]] || { echo "ERROR: .kiro/ not found — run from the project" >&2; exit 2; }
ENGINE=".kiro/skills/sql-conversion/scripts"
RES="$(mktemp -t agents-results.XXXXXX)"; trap 'rm -f "$RES"' EXIT
rc=0
echo "################ 1. agent structural tests ################"
set +e; python3 .kiro/agents/hooks/tests/test_agents.py --results "$RES"; t=$?; set -e
python3 "$ENGINE/check_rule_coverage.py" --results "$RES" --no-steering --catalog .kiro/agents/AGENTS.md --prefix AG || rc=1
[[ $t -ne 0 ]] && rc=1
echo "################ 2. kiro-cli ################"
if command -v kiro-cli >/dev/null; then
    for f in sql-migration-agent sql-reporting-agent sql-migration-agent-windows sql-reporting-agent-windows; do
        if kiro-cli agent validate --path ".kiro/agents/$f.json"; then echo "valid: $f"; else echo "INVALID: $f"; rc=1; fi
    done
    n=$(kiro-cli agent list 2>&1 | sed 's/\x1b\[[0-9;]*m//g' | grep -cE "^[[:space:]]*sql-(migration|reporting)-agent(-windows)?[[:space:]]+Workspace" || true)
    if [[ "$n" -ge 4 ]]; then echo "listed as Workspace agents: $n"; else echo "agents not all listed as Workspace agents ($n/4) — run inside the trusted project"; rc=1; fi
else
    echo "kiro-cli not installed: skipped validate/list (install Kiro CLI to run the agents)"
fi
if [[ "${1:-}" == "--smoke" ]]; then
    echo "################ 3. headless smoke prompts (read-only) ################"
    command -v kiro-cli >/dev/null || { echo "kiro-cli required for --smoke" >&2; exit 2; }
    set +e
    kiro-cli chat --no-interactive --trust-tools=fs_read --agent sql-migration-agent "List the intake questions you would ask before converting source/schema/sales_db_schema.sql to Redshift. Do not run tools." | tail -20; s1=$?
    kiro-cli chat --no-interactive --trust-tools=fs_read --agent sql-reporting-agent "Which pattern (RP-nn) and dialect rules (RD-nn) apply to 'monthly revenue with gap filling on Athena'? Answer from the skill, do not run tools." | tail -20; s2=$?
    set -e
    [[ $s1 -eq 0 && $s2 -eq 0 ]] || { echo "smoke prompts failed ($s1/$s2)"; rc=1; }
fi
[[ $rc -eq 0 ]] && echo "AGENTS: PASS" || { echo "AGENTS: FAIL" >&2; exit 1; }
