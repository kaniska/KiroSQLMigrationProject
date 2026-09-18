#!/usr/bin/env bash
# ============================================================
# sql-conversion-iceberg skill — self-test (no database needed; Athena is exercised
# through the stub AWS CLI, and for real only when ATHENA_DATABASE + ATHENA_WORKGROUP are set)
#   1. unit tests for iceberg_tool.py on fixtures and on references/examples
#   2. checks that every IB-nn row of references/corner-cases.md has a tagged test
# Needs the sql-conversion skill next to this one (shared migkit and coverage checker).
# ============================================================
set -euo pipefail
SCRIPTS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENGINE="$SCRIPTS/../../sql-conversion/scripts"
[[ -f "$ENGINE/check_rule_coverage.py" ]] || { echo "ERROR: shared engine not found at $ENGINE (install the sql-conversion skill)" >&2; exit 2; }
RESULTS="$(mktemp -t iceberg-results.XXXXXX)"; trap 'rm -f "$RESULTS"' EXIT
set +e
python3 "$SCRIPTS/tests/test_iceberg_tool.py" --results "$RESULTS"; unit=$?
python3 "$ENGINE/check_rule_coverage.py" --results "$RESULTS" --no-steering --catalog "$SCRIPTS/../references/corner-cases.md" --prefix IB; cov=$?
set -e
if [[ $unit -eq 0 && $cov -eq 0 ]]; then echo "SKILL SELF-TEST: PASS"; exit 0; fi
echo "SKILL SELF-TEST: FAIL (unit $unit, coverage $cov)" >&2; exit 1
