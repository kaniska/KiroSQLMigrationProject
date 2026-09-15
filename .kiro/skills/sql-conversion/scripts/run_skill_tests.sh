#!/usr/bin/env bash
# ============================================================
# sql-conversion skill — self-test
#   1. loads the sample schema + every worked example into a TEST database
#   2. runs static checks, example tests and corner-case tests
#   3. checks that every hard rule, parity rule and corner case has a test
#   4. migkit unit tests (security scanner, audit log, AWS/local services with a stub AWS CLI)
#      and coverage of references/security-logging.md (SEC/LOG/SVC)
#
# Connection: standard PG* variables; PG_IAM_AUTH=1 + AWS_REGION for
# RDS/Aurora IAM auth (see scripts/pgtest.sh). Requires PostgreSQL 17.
#
#   PGHOST=… PGDATABASE=my_test_db PGUSER=… bash .kiro/skills/sql-conversion/scripts/run_skill_tests.sh
# ============================================================
set -euo pipefail
SCRIPTS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RESULTS="$(mktemp -t sqlconv-results.XXXXXX)"
trap 'rm -f "$RESULTS"' EXIT

set +e
bash "$SCRIPTS/pgtest.sh" "$SCRIPTS/selftest.sql" --results "$RESULTS"
rc=$?
set -e
[[ $rc -eq 2 ]] && exit 2          # could not connect / setup problem

echo "################ migkit: security, audit, AWS/local services ################"
set +e
python3 "$SCRIPTS/tests/test_migkit.py" --results "$RESULTS"; kit=$?
python3 "$SCRIPTS/check_rule_coverage.py" --results "$RESULTS"
cov=$?
python3 "$SCRIPTS/check_rule_coverage.py" --results "$RESULTS" --no-steering \
    --catalog "$SCRIPTS/../references/security-logging.md" --prefix SEC --prefix LOG --prefix SVC
seccov=$?
set -e

if [[ $rc -eq 0 && $cov -eq 0 && $kit -eq 0 && $seccov -eq 0 ]]; then
    echo "SKILL SELF-TEST: PASS"
    exit 0
fi
echo "SKILL SELF-TEST: FAIL (tests exit $rc, coverage exit $cov, migkit exit $kit, security coverage exit $seccov)" >&2
exit 1
