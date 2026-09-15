#!/usr/bin/env bash
# ============================================================
# informatica-etl-conversion skill — self-test
#   1. Python unit tests for infa_sql_tool.py and the worked examples
#   2. re-generates each example's .postgres.xml from its converted SQL and checks it
#      is identical to the committed file; static checks; renders the SQL
#   3. runs the rendered SQL + assertions on a PostgreSQL 15+ TEST database
#   4. checks every corner case IC-nn has a tagged test
# Needs the sql-conversion skill next to this one (shared engine). Connection: PG*
# variables; PG_IAM_AUTH=1 + AWS_REGION for Aurora IAM auth.
# ============================================================
set -euo pipefail
SCRIPTS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL="$(dirname "$SCRIPTS")"
ENGINE="$SCRIPTS/../../sql-conversion/scripts"
EX="$SKILL/references/examples"
TOOL="python3 $SCRIPTS/infa_sql_tool.py"
export MIGRATION_LINEAGE=0   # regenerating the committed examples verifies them; it is not a migration, so no lineage events
[[ -f "$ENGINE/pgtest.sh" ]] || { echo "ERROR: shared test engine not found at $ENGINE (install the sql-conversion skill)" >&2; exit 2; }
RESULTS="$(mktemp -t infa-results.XXXXXX)"; SQLRES="$(mktemp -t infa-sqlres.XXXXXX)"; TMPX="$(mktemp -d -t infa-xml.XXXXXX)"
trap 'rm -rf "$RESULTS" "$SQLRES" "$TMPX"' EXIT

echo "################ 1. tool unit tests ################"
set +e; python3 "$SCRIPTS/tests/test_infa_tool.py" --results "$RESULTS"; py=$?; set -e

echo "################ 2. regenerate, check, render examples ################"
mkdir -p "$SCRIPTS/.generated"; gen=0
for n in 01_orders_incremental 02_customer_dim 03_shipping_procs 04_product_sales_session_override 05_customer_summary_real_export; do
    $TOOL inject "$EX/$n.sqlserver.xml" "$EX/$n.sql" "$TMPX/$n.postgres.xml" --map "$EX/params/pg_map.json" >/dev/null
    if ! cmp -s "$TMPX/$n.postgres.xml" "$EX/$n.postgres.xml"; then
        echo "FAIL  $n.postgres.xml is out of date — regenerate with: infa_sql_tool.py inject ... --map params/pg_map.json"; gen=1
    fi
    $TOOL check "$EX/$n.sql" --source-dir "$EX/$n.sql" --xml "$EX/$n.postgres.xml" | tail -1 | sed "s/^/  $n: /"
    $TOOL render "$EX/$n.sql" "$SCRIPTS/.generated/$n.rendered.sql" \
        --params "$EX/params/etl_params.prm" --bindings "$EX/params/test_bindings.json" --prefix "ex${n:0:2}_" >/dev/null
done

echo "################ 3. PostgreSQL tests ################"
set +e; bash "$ENGINE/pgtest.sh" "$SCRIPTS/selftest.sql" --results "$SQLRES"; rc=$?; set -e
[[ $rc -eq 2 ]] && exit 2
cat "$SQLRES" >> "$RESULTS"

echo "################ 4. corner-case coverage ################"
set +e
python3 "$ENGINE/check_rule_coverage.py" --results "$RESULTS" --no-steering --catalog "$SKILL/references/corner-cases.md" --prefix IC; cov=$?
set -e
if [[ $py -eq 0 && $gen -eq 0 && $rc -eq 0 && $cov -eq 0 ]]; then echo "SKILL SELF-TEST: PASS"; exit 0; fi
echo "SKILL SELF-TEST: FAIL (unit $py, regenerate $gen, sql $rc, coverage $cov)" >&2; exit 1
