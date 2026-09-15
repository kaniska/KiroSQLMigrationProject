#!/usr/bin/env bash
# ============================================================
# SQLMigrationProject — test entry point
#
#   bash supporting-files/run_tests.sh             # project suites + all three skill self-tests + rule coverage
#   bash supporting-files/run_tests.sh --project   # project suites only (tests/test_runner.sql)
#   bash supporting-files/run_tests.sh --skill     # skill self-tests only (sql-conversion, sql-reporting, informatica-etl-conversion)
#                                         + agent guardrail/audit hook tests (.kiro/agents/hooks/tests)
#
#   One correlation id (MIGRATION_RUN_ID) covers the whole run: every audit record, every
#   PostgreSQL session (application_name mig:<manifest>:<run8>) and every test result carry it.
#   At the end pending audit records and lineage events are shipped to AWS when configured
#   (.kiro/settings/migration-services.json), otherwise they stay in logs/.
#
#   TEST_TARGET=rds   (default) Aurora PostgreSQL via IAM auth, values from
#                     metadata/test_connection.env
#   TEST_TARGET=local local PostgreSQL 17 (PGHOST/PGPORT/PGUSER/PGDATABASE honoured)
#
# Exit code: 0 all passed · non-zero otherwise.
# ============================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
if [[ ! -d "$PROJECT_DIR/.kiro" ]]; then
    if [[ -d "$PROJECT_DIR/kiro" ]]; then
        echo "ERROR: found 'kiro/' but no '.kiro/'. Kiro only loads a folder named exactly .kiro — rename it back: mv kiro .kiro" >&2
    else
        echo "ERROR: .kiro/ not found in $PROJECT_DIR (steering, skills, agents and hooks live there)" >&2
    fi
    exit 2
fi
ENGINE="$PROJECT_DIR/.kiro/skills/sql-conversion/scripts"
KIT="$ENGINE/migkit"
export MIGRATION_RUN_ID="$(python3 "$KIT/audit.py" current-run-id)"
audit() { python3 "$KIT/audit.py" emit --service run_tests "$@" >/dev/null 2>&1 || true; }

MODE="all"
case "${1:-}" in
    --project) MODE="project" ;;
    --skill)   MODE="skill" ;;
    "")        ;;
    *) echo "usage: $0 [--project|--skill]" >&2; exit 2 ;;
esac

# shellcheck source=../metadata/test_connection.env
source "$PROJECT_DIR/metadata/test_connection.env"
case "${TEST_TARGET:-rds}" in
    rds)
        export PGHOST="${PGHOST:-$RDS_PGHOST}" PGPORT="${PGPORT:-$RDS_PGPORT}"
        export PGDATABASE="${PGDATABASE:-$RDS_PGDATABASE}" PGUSER="${PGUSER:-$RDS_PGUSER}"
        export AWS_REGION="${AWS_REGION:-$RDS_AWS_REGION}" PG_IAM_AUTH=1
        ;;
    local)
        export PGHOST="${PGHOST:-$LOCAL_PGHOST}" PGPORT="${PGPORT:-$LOCAL_PGPORT}"
        export PGDATABASE="${PGDATABASE:-$LOCAL_PGDATABASE}" PGUSER="${PGUSER:-$USER}"
        export PG_IAM_AUTH=0
        # a throw-away local cluster is usually reached as a superuser; Aurora runs refuse that
        export PGTEST_ALLOW_SUPERUSER="${PGTEST_ALLOW_SUPERUSER:-1}"
        ;;
    *) echo "ERROR: TEST_TARGET must be 'rds' or 'local'" >&2; exit 2 ;;
esac

echo "Run id: $MIGRATION_RUN_ID   (troubleshoot: python3 $KIT/audit.py tail --run ${MIGRATION_RUN_ID:0:8})"
audit --event tests.run.start --attr "mode=$MODE" --attr "target=${TEST_TARGET:-rds}" --attr "db.name=$PGDATABASE"
project_rc=0; skill_rc=0; hooks_rc=0
if [[ "$MODE" != "skill" ]]; then
    echo "################ PROJECT SUITES ################"
    set +e; bash "$ENGINE/pgtest.sh" "$PROJECT_DIR/tests/test_runner.sql"; project_rc=$?; set -e
fi
if [[ "$MODE" != "project" ]]; then
    for skill in sql-conversion sql-reporting informatica-etl-conversion; do
        echo "################ SKILL SELF-TEST: $skill ################"
        set +e; bash "$PROJECT_DIR/.kiro/skills/$skill/scripts/run_skill_tests.sh"; rc=$?; set -e
        [[ $rc -ne 0 ]] && skill_rc=$rc
        echo "Skill $skill: $([[ $rc -eq 0 ]] && echo PASS || echo "FAIL ($rc)")"
    done
    echo "################ AGENT HOOKS: guardrails + audit ################"
    HRES="$(mktemp -t hooks-results.XXXXXX)"
    set +e
    python3 "$PROJECT_DIR/.kiro/agents/hooks/tests/test_hooks.py" --results "$HRES" 2>&1 | tail -3; hooks_rc=${PIPESTATUS[0]}
    python3 "$ENGINE/check_rule_coverage.py" --results "$HRES" --no-steering \
        --catalog "$PROJECT_DIR/.kiro/agents/hooks/GUARDRAILS.md" --prefix GRD --prefix HOOK || hooks_rc=1
    set -e
    rm -f "$HRES"
fi

echo "=================================================="
[[ "$MODE" != "skill"   ]] && echo "Project suites : $([[ $project_rc -eq 0 ]] && echo PASS || echo "FAIL ($project_rc)")"
[[ "$MODE" != "project" ]] && echo "Skill self-tests: $([[ $skill_rc -eq 0 ]] && echo PASS || echo "FAIL ($skill_rc)")"
[[ "$MODE" != "project" ]] && echo "Agent hooks    : $([[ $hooks_rc -eq 0 ]] && echo PASS || echo "FAIL ($hooks_rc)")"
echo "Run id         : $MIGRATION_RUN_ID"
audit --event tests.run.end --severity "$([[ $project_rc -eq 0 && $skill_rc -eq 0 && $hooks_rc -eq 0 ]] && echo INFO || echo ERROR)" \
      --attr "project_rc=$project_rc" --attr "skill_rc=$skill_rc" --attr "hooks_rc=$hooks_rc"
python3 "$KIT/services.py" sync >/dev/null 2>&1 || echo "note: audit/lineage sync to AWS skipped (see: python3 $KIT/services.py status)"
if [[ $project_rc -eq 0 && $skill_rc -eq 0 && $hooks_rc -eq 0 ]]; then echo "RESULT: PASS"; exit 0; fi
echo "RESULT: FAIL" >&2
exit 1
