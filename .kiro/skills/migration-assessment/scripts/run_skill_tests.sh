#!/usr/bin/env bash
# ============================================================
# migration-assessment skill — self-test (no database needed)
#   1. unit tests for assess_tool.py on fixtures and on this project's source/ folder
#   2. checks that every MA-nn row of references/placement-matrix.md has a tagged test
# Needs the sql-conversion skill next to this one (shared migkit and coverage checker).
# ============================================================
set -euo pipefail
SCRIPTS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENGINE="$SCRIPTS/../../sql-conversion/scripts"
[[ -f "$ENGINE/check_rule_coverage.py" ]] || { echo "ERROR: shared engine not found at $ENGINE (install the sql-conversion skill)" >&2; exit 2; }
RESULTS="$(mktemp -t assess-results.XXXXXX)"; trap 'rm -f "$RESULTS"' EXIT
set +e
python3 "$SCRIPTS/tests/test_assess_tool.py" --results "$RESULTS"; unit=$?
python3 "$ENGINE/check_rule_coverage.py" --results "$RESULTS" --no-steering --catalog "$SCRIPTS/../references/placement-matrix.md" --prefix MA; cov=$?
set -e
if [[ $unit -eq 0 && $cov -eq 0 ]]; then echo "SKILL SELF-TEST: PASS"; exit 0; fi
echo "SKILL SELF-TEST: FAIL (unit $unit, coverage $cov)" >&2; exit 1
