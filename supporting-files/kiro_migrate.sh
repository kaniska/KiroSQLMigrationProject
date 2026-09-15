#!/usr/bin/env bash
# ============================================================
# Headless batch migration with Kiro CLI and the sql-migration-agent.
#
#   bash supporting-files/kiro_migrate.sh                      # every source file not yet in the migration log
#   bash supporting-files/kiro_migrate.sh source/usp_A.sql …   # just these files
#
# For each file the agent follows the sql-conversion skill: converts, adds tests,
# updates metadata/migration_log.json and runs the project tests. One log per file
# in logs/. A full test run (project + skill self-test + coverage) closes the batch.
#
# Permissions: by default only what .kiro/agents/sql-migration-agent.json
# auto-approves is allowed (reads, writes under generated/ tests/ metadata/,
# the test commands). Set TRUST_TOOLS=1 to add
# --trust-tools=fs_read,fs_write,execute_bash (broader: any shell command).
# Headless Kiro CLI may require KIRO_API_KEY — see the Kiro CLI docs.
# The agent's preToolUse guard hook applies in every mode, including TRUST_TOOLS=1.
#
# Security and audit: one batch run id (MIGRATION_RUN_ID) for every agent session, tool and test;
# each source file is scanned first (prompt injection, hidden characters, credentials, unsafe XML)
# and skipped when flagged unless ALLOW_FLAGGED_INPUTS=1; converted files are archived with a
# sha256 manifest (and to S3 when configured) and audit/lineage records are synced at the end.
# ============================================================
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 2
PROJECT_DIR="$(pwd)"
if [[ ! -d "$PROJECT_DIR/.kiro" ]]; then
    if [[ -d "$PROJECT_DIR/kiro" ]]; then
        echo "ERROR: found 'kiro/' but no '.kiro/'. Kiro only loads a folder named exactly .kiro — rename it back: mv kiro .kiro" >&2
    else
        echo "ERROR: .kiro/ not found in $PROJECT_DIR (steering, skills, agents and hooks live there)" >&2
    fi
    exit 2
fi
command -v kiro-cli >/dev/null || { echo "kiro-cli not found (https://kiro.dev/docs/cli)" >&2; exit 2; }
mkdir -p logs
KIT=".kiro/skills/sql-conversion/scripts/migkit"
export MIGRATION_RUN_ID="$(python3 "$KIT/audit.py" current-run-id)"
audit() { python3 "$KIT/audit.py" emit --service kiro_migrate "$@" >/dev/null 2>&1 || true; }
echo "Batch run id: $MIGRATION_RUN_ID"

files=("$@")
if [[ ${#files[@]} -eq 0 ]]; then
    PENDING_PY='import json,pathlib
log=json.loads(pathlib.Path("metadata/migration_log.json").read_text())
done={f.get("source_file") for f in log.get("files",[])}
print("\n".join(p.as_posix() for p in sorted(pathlib.Path("source").glob("*.sql")) if p.as_posix() not in done))'
    while IFS= read -r f; do [[ -n "$f" ]] && files+=("$f"); done < <(python3 -c "$PENDING_PY")
fi
[[ ${#files[@]} -eq 0 ]] && { echo "Nothing pending — every source file is in metadata/migration_log.json."; exit 0; }

trust=()
[[ "${TRUST_TOOLS:-0}" == "1" ]] && trust=(--trust-tools=fs_read,fs_write,execute_bash)

failed=(); skipped=()
audit --event batch.start --attr "files=${#files[@]}" --attr "trust_tools=${TRUST_TOOLS:-0}"
for f in "${files[@]}"; do
    name="$(basename "$f" .sql)"
    if ! python3 "$KIT/security.py" scan "$f" --fail-on high > "logs/$name.security.txt" 2>&1; then
        if [[ "${ALLOW_FLAGGED_INPUTS:-0}" != "1" ]]; then
            echo "!! $f skipped: security findings (see logs/$name.security.txt; ALLOW_FLAGGED_INPUTS=1 to convert anyway)"
            audit --event batch.file_skipped --severity WARN --attr "file=$f" --attr reason=security_findings
            skipped+=("$f"); continue
        fi
        echo "!! $f has security findings — converting because ALLOW_FLAGGED_INPUTS=1 (the agent is told to treat them as data)"
    fi
    audit --event batch.file_start --attr "file=$f"
    echo ">> $f  (log: logs/$name.log)"
    if ! kiro-cli chat --no-interactive --agent sql-migration-agent ${trust[@]+"${trust[@]}"} \
        "Convert $f to PostgreSQL following the sql-conversion skill (Steps 1-10). Register the converted file in tests/test_runner.sql, add tagged suites to tests/test_cases.sql, update metadata/migration_log.json, run 'bash supporting-files/run_tests.sh --project' until it prints RESULT: PASS, then give the report." \
        > "logs/$name.log" 2>&1; then
        echo "   kiro-cli exited non-zero — see logs/$name.log"
        failed+=("$f")
    fi
done

echo "== Final verification =="
bash supporting-files/run_tests.sh
rc=$?
python3 "$KIT/services.py" archive generated metadata/migration_log.json --label batch >/dev/null 2>&1 || true
python3 "$KIT/services.py" sync >/dev/null 2>&1 || true
audit --event batch.end --severity "$([[ $rc -eq 0 && ${#failed[@]} -eq 0 ]] && echo INFO || echo ERROR)" \
      --attr "tests_rc=$rc" --attr "failed=${#failed[@]}" --attr "skipped=${#skipped[@]}"
[[ ${#failed[@]} -gt 0 ]] && echo "Files needing attention: ${failed[*]}"
[[ ${#skipped[@]} -gt 0 ]] && echo "Files skipped by the security scan: ${skipped[*]}"
echo "Audit trail: python3 $KIT/audit.py tail --run ${MIGRATION_RUN_ID:0:8}"
exit $(( rc != 0 || ${#failed[@]} > 0 || ${#skipped[@]} > 0 ))
