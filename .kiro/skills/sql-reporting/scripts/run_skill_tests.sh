#!/usr/bin/env bash
# ============================================================
# sql-reporting skill — self-test
#   1. loads the sample schema + reporting fixtures + 15 example reports into a TEST db
#   2. runs the pattern tests and the query-rule tests
#   3. runs the dialect tests (Redshift / Athena / Spark examples through report_tool.py check)
#   4. checks that every RQ-nn rule, RP-nn pattern and RD-nn dialect rule has a tagged test
# Needs the sql-conversion skill next to this one (shared test engine).
# Connection: PG* variables; PG_IAM_AUTH=1 + AWS_REGION for Aurora IAM auth.
# ============================================================
set -euo pipefail
SCRIPTS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENGINE="$SCRIPTS/../../sql-conversion/scripts"
[[ -f "$ENGINE/pgtest.sh" ]] || { echo "ERROR: shared test engine not found at $ENGINE (install the sql-conversion skill)" >&2; exit 2; }
RESULTS="$(mktemp -t sqlrep-results.XXXXXX)"; trap 'rm -f "$RESULTS"' EXIT

set +e
bash "$ENGINE/pgtest.sh" "$SCRIPTS/selftest.sql" --results "$RESULTS"; rc=$?
set -e
[[ $rc -eq 2 ]] && exit 2
echo "################ dialect checks: Redshift · Athena · Spark (report_tool.py) ################"
set +e
python3 "$SCRIPTS/tests/test_report_dialects.py" --results "$RESULTS"; py=$?
python3 "$ENGINE/check_rule_coverage.py" --results "$RESULTS" --no-steering \
    --catalog "$SCRIPTS/../references/patterns.md" --prefix RQ --prefix RP; cov=$?
python3 "$ENGINE/check_rule_coverage.py" --results "$RESULTS" --no-steering \
    --catalog "$SCRIPTS/../references/dialects.md" --prefix RD; cov2=$?
set -e
if [[ $rc -eq 0 && $py -eq 0 && $cov -eq 0 && $cov2 -eq 0 ]]; then echo "SKILL SELF-TEST: PASS"; exit 0; fi
echo "SKILL SELF-TEST: FAIL (tests exit $rc, dialect tests $py, coverage $cov/$cov2)" >&2; exit 1
