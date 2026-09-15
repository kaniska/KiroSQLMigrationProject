#!/usr/bin/env bash
# ============================================================
# sql-conversion skill — generic PostgreSQL test runner
#
#   pgtest.sh <manifest.sql> [--results FILE]
#
# <manifest.sql> is a psql script that \ir-includes, in order:
#   lib/guard_and_reset.sql → schema → seed → lib/test_framework.sql →
#   converted objects → test suites → lib/report.sql
# (see scripts/selftest.sql or your project's tests/test_runner.sql).
#
# Connection: the standard libpq variables PGHOST PGPORT PGDATABASE PGUSER
# PGPASSWORD PGSSLMODE. For Amazon RDS / Aurora IAM database authentication
# set PG_IAM_AUTH=1 and AWS_REGION: a 15-minute token is generated with
# `aws rds generate-db-auth-token` and used as the password.
#
# Correlation and guardrails (migkit, next to this script):
#   * one run id per run: MIGRATION_RUN_ID (inherited from the caller or the Kiro agent session,
#     else new) — visible in PostgreSQL as application_name mig:<manifest>:<run8> and as the
#     setting migration.run_id, stored with every test result, and on every audit record;
#   * preflight security scan of the manifest and all included files (psql shell escapes,
#     hidden characters, credentials) — blocking unless PGTEST_ALLOW_DANGEROUS=1;
#   * superuser / rds_superuser connections are refused unless PGTEST_ALLOW_SUPERUSER=1;
#   * PG_SECRET_FROM_SERVICES=1 reads the connection from AWS Secrets Manager via
#     migkit/services.py (never printed); audit events pgtest.start / pgtest.end.
#
# Exit code: 0 all tests passed · 3 failures/errors · 2 setup problem · 4 refused by preflight.
# ============================================================
set -euo pipefail

MANIFEST="${1:?usage: pgtest.sh <manifest.sql> [--results FILE]}"
shift
RESULTS_FILE=""
if [[ "${1:-}" == "--results" ]]; then RESULTS_FILE="${2:?--results needs a file}"; shift 2; fi
[[ -f "$MANIFEST" ]] || { echo "ERROR: manifest not found: $MANIFEST" >&2; exit 2; }
KIT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/migkit"
command -v python3 >/dev/null || { echo "ERROR: python3 not found (needed for the audit log and preflight scan)" >&2; exit 2; }

# Credentials from AWS Secrets Manager (when configured) — re-exec once with them in the environment
if [[ "${PG_SECRET_FROM_SERVICES:-0}" == "1" && -z "${_PGTEST_SECRETS_LOADED:-}" ]]; then
    export _PGTEST_SECRETS_LOADED=1
    exec python3 "$KIT/services.py" exec -- bash "${BASH_SOURCE[0]}" "$MANIFEST" "$@"
fi

export MIGRATION_RUN_ID="$(python3 "$KIT/audit.py" current-run-id)"
STEM="$(basename "$MANIFEST" .sql)"
export PGAPPNAME="${PGAPPNAME:-mig:${STEM:0:40}:${MIGRATION_RUN_ID:0:8}}"
export PGOPTIONS="${PGOPTIONS:+$PGOPTIONS }-c migration.run_id=$MIGRATION_RUN_ID"
audit() { python3 "$KIT/audit.py" emit --service pgtest "$@" >/dev/null 2>&1 || true; }

# Prefer the newest Homebrew PostgreSQL client when present
for v in 18 17 16 15; do
    if [[ -x "/opt/homebrew/opt/postgresql@$v/bin/psql" ]]; then
        export PATH="/opt/homebrew/opt/postgresql@$v/bin:$PATH"; break
    fi
done
command -v psql >/dev/null || { echo "ERROR: psql not found (e.g. brew install postgresql@17)" >&2; exit 2; }
: "${PGDATABASE:?set PGDATABASE (a database whose name contains test/dev/sandbox/local)}"

if [[ "${PG_IAM_AUTH:-0}" == "1" ]]; then
    : "${PGHOST:?PG_IAM_AUTH=1 needs PGHOST}" "${PGUSER:?PG_IAM_AUTH=1 needs PGUSER}"
    : "${AWS_REGION:?PG_IAM_AUTH=1 needs AWS_REGION}"
    command -v aws >/dev/null || { echo "ERROR: aws CLI not found (needed for IAM auth)" >&2; exit 2; }
    PGPASSWORD="$(aws rds generate-db-auth-token --hostname "$PGHOST" --port "${PGPORT:-5432}" \
                   --username "$PGUSER" --region "$AWS_REGION")" \
        || { echo "ERROR: could not generate an IAM auth token (check AWS credentials)" >&2; exit 2; }
    export PGPASSWORD
    export PGSSLMODE="${PGSSLMODE:-require}"
fi
export PGCONNECT_TIMEOUT="${PGCONNECT_TIMEOUT:-15}"

echo "Run id:   $MIGRATION_RUN_ID (application_name $PGAPPNAME)"
set +e; python3 "$KIT/security.py" preflight "$MANIFEST"; pre=$?; set -e
if [[ $pre -ne 0 ]]; then
    if [[ "${PGTEST_ALLOW_DANGEROUS:-0}" == "1" ]]; then
        echo "WARNING: preflight findings overridden by PGTEST_ALLOW_DANGEROUS=1" >&2
        audit --event pgtest.preflight_override --severity WARN --attr "manifest=$MANIFEST"
    else
        echo "REFUSED: the manifest or an included file failed the security preflight (see above)." >&2
        audit --event pgtest.refused --severity ERROR --attr "manifest=$MANIFEST" --attr reason=preflight
        exit 4
    fi
fi
echo "Manifest: $MANIFEST"
echo "Target:   ${PGUSER:-$USER}@${PGHOST:-local socket}:${PGPORT:-5432}/$PGDATABASE$([[ "${PG_IAM_AUTH:-0}" == 1 ]] && echo ' (IAM auth)')"

args=(-X -v ON_ERROR_STOP=1 -v "run_id=$MIGRATION_RUN_ID")
[[ -n "$RESULTS_FILE" ]] && args+=(-v "results_file=$RESULTS_FILE")
[[ "${PGTEST_ALLOW_SUPERUSER:-0}" == "1" ]] && args+=(-v allow_superuser=1)

MANIFEST_SHA="$(python3 -c 'import hashlib,sys;print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' "$MANIFEST")"
audit --event pgtest.start --attr "manifest=$MANIFEST" --attr "manifest_sha256=$MANIFEST_SHA" \
      --attr "db.host=${PGHOST:-local}" --attr "db.name=$PGDATABASE" --attr "db.user=${PGUSER:-$USER}" \
      --attr "iam_auth=${PG_IAM_AUTH:-0}" --attr "application_name=$PGAPPNAME"
START_S=$SECONDS
set +e
psql "${args[@]}" -f "$MANIFEST"
rc=$?
set -e
summary=""
if [[ -n "$RESULTS_FILE" && -f "$RESULTS_FILE" ]]; then
    summary="$(awk -F'\t' '{c[$1]++} END {printf "pass=%d fail=%d error=%d", c["PASS"], c["FAIL"], c["ERROR"]}' "$RESULTS_FILE")"
fi
audit --event pgtest.end --severity "$([[ $rc -eq 0 ]] && echo INFO || echo ERROR)" --attr "manifest=$MANIFEST" \
      --attr "exit_code=$rc" --attr "duration_s=$((SECONDS - START_S))" --attr "results=$summary"
if [[ $rc -eq 0 ]]; then echo "RESULT: PASS (run $MIGRATION_RUN_ID)"; else echo "RESULT: FAIL (psql exit code $rc, run $MIGRATION_RUN_ID)" >&2; fi
exit $rc
