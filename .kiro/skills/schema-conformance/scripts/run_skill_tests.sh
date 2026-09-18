#!/usr/bin/env bash
# ============================================================
# schema-conformance skill — self-test (no database needed; live PostgreSQL is used only when PGHOST/PGDATABASE point at a test database; Glue is exercised
# through the stub AWS CLI)
#   1. unit tests for schema_tool.py on fixtures and on this project's source/schema and generated/schema.sql
#   2. checks that every SC-nn row of references/conformance-rules.md has a tagged test
# Needs the sql-conversion skill next to this one (shared migkit and coverage checker).
# ============================================================
set -euo pipefail
SCRIPTS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENGINE="$SCRIPTS/../../sql-conversion/scripts"
[[ -f "$ENGINE/check_rule_coverage.py" ]] || { echo "ERROR: shared engine not found at $ENGINE (install the sql-conversion skill)" >&2; exit 2; }
RESULTS="$(mktemp -t schema-results.XXXXXX)"; trap 'rm -f "$RESULTS"' EXIT
set +e
python3 "$SCRIPTS/tests/test_schema_tool.py" --results "$RESULTS"; unit=$?
python3 "$ENGINE/check_rule_coverage.py" --results "$RESULTS" --no-steering --catalog "$SCRIPTS/../references/conformance-rules.md" --prefix SC; cov=$?
set -e
if [[ $unit -eq 0 && $cov -eq 0 ]]; then echo "SKILL SELF-TEST: PASS"; exit 0; fi
echo "SKILL SELF-TEST: FAIL (unit $unit, coverage $cov)" >&2; exit 1
