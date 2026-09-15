# Security, audit logging and AWS service catalog (migkit)

`scripts/migkit/` is shared by all migration skills and the example agent. It implements
deterministic controls **outside the model**: whatever text an input file contains, these checks
run the same way. Every row below has at least one executed test (`scripts/tests/test_migkit.py`,
`scripts/tests/engine_tests.sql`, and the Informatica tests `IC-36…IC-44`);
`check_rule_coverage.py --catalog references/security-logging.md` fails the self-test otherwise.

Background: OWASP Top 10 for LLM Applications (LLM01 prompt injection, LLM02 sensitive
information disclosure, LLM05 improper output handling, LLM06 excessive agency) and AWS guidance
for agentic AI (least privilege, deterministic guardrails outside the model, human approval for
irreversible actions, complete audit trails).

## Security rules (SEC)

| ID | Control | Where it runs | Severity | Test |
|---|---|---|---|---|
| SEC-01 | Instruction-like text aimed at an AI agent (ignore previous instructions, you are now…, run this command, do not tell the user, exfiltrate credentials, disable tests/hooks, edit `.kiro/`) | `security.scan_text`; Informatica extract/check; agent hooks on prompts, files and writes | high | auto |
| SEC-02 | Invisible, bidirectional-control and tag Unicode characters (Trojan Source) | same | high | auto |
| SEC-03 | Credentials: AWS keys, private keys, `password=`, credentials in URIs, `CREATE LOGIN … PASSWORD`, Informatica password attributes, `.prm` passwords | same; audit log redaction | critical | auto |
| SEC-04 | Dangerous PostgreSQL: `COPY … PROGRAM`, server files, `lo_import`, untrusted languages, `ALTER SYSTEM`, role switch/management, dblink/FDW/`aws_s3`/`aws_lambda`, `SECURITY DEFINER`, grants, event triggers | scanner; Informatica check/render; agent write hook | critical / high | auto |
| SEC-05 | Dangerous SQL Server constructs in sources: `xp_cmdshell`, `OPENROWSET`, `BULK INSERT`, `EXECUTE AS LOGIN`, `sp_configure`, linked servers, CLR, `DBCC`, `sp_send_dbmail` | scanner | high (manual review) | auto |
| SEC-06 | Unsafe XML: DOCTYPE internal subset, ENTITY declarations, external/remote DTDs other than `powrmart.dtd`, malformed XML | `security.safe_parse_xml` before ElementTree | critical | auto |
| SEC-07 | Unsafe paths: traversal, absolute, symlinks, outside the working folder; least-privilege database role (no superuser) | `check_path`; Informatica manifests; `guard_and_reset.sql` | critical | auto |
| SEC-08 | Parameter / binding values that break out of SQL literals (`'`, `;`, `--`, `/*`, dollar quotes, backslash, NUL) | `check_value_safe`; Informatica render | high | auto |
| SEC-09 | Dangerous constructs, network references, injection or hidden text that appear only in converted output (not justified by the source) | `diff_introduced`; Informatica inject/check | critical | auto |
| SEC-10 | Outbound network references (URLs, S3 URIs) | scanner | info | auto |
| SEC-11 | Oversized inputs (`MIGRATION_MAX_INPUT_BYTES`, default 50 MB), nesting > 200 | `check_size`, `safe_parse_xml` | critical | auto |
| SEC-12 | psql test manifest preflight: `\!`, `\o |`, `\copy … program`, `\setenv`, `\lo_import` plus SEC-02/03 in every included file | `security.py preflight`, `pgtest.sh` (exit 4) | critical | auto |
| SEC-13 | Amazon Bedrock Guardrails `ApplyGuardrail` intervention (prompt attack, sensitive information), per-run character budget | `services.guardrail` (when configured) | high | auto |

## Audit logging rules (LOG)

| ID | Requirement | Implementation | Test |
|---|---|---|---|
| LOG-01 | One JSON record per event in the OpenTelemetry log data model: `timestamp` (RFC 3339 UTC, milliseconds), `severity_text`/`severity_number`, `event`, `body`, `trace_id`, `span_id`, `parent_span_id`, `traceparent`, `resource` (service, version, host, user, pid), `attributes` | `audit.AuditLogger` → `logs/audit/audit-YYYYMMDD.jsonl` | auto |
| LOG-02 | One correlation id per run (`run_id` = W3C trace id, X-Ray id `1-<8>-<24>` derivable): inherited from `MIGRATION_RUN_ID`, else from the active Kiro agent session (`logs/state/current_session.json`, written by the agentSpawn hook), else new; child processes get `MIGRATION_RUN_ID` + `TRACEPARENT` | `audit.run_id`, `child_env` | auto |
| LOG-03 | Tamper evidence: `seq`, `prev_hash`, `hash` (SHA-256 chain), file-locked appends from many processes; `audit.py verify` | `audit.py` | auto |
| LOG-04 | No secrets in logs: key-name and value-pattern redaction (passwords, tokens, AWS keys, private keys, URI credentials, RDS IAM token signatures), long values truncated; prompts logged as length + SHA-256 only | `audit.redact`, hooks | auto |
| LOG-05 | Spans for every command: `<name>.start`, `<name>.end` with `duration_ms`, `status` ok/failed/error, `exit_code`; `<name>.error` with the exception type | `AuditLogger.span`; Informatica tool | auto |
| LOG-06 | Database-side correlation: `application_name = mig:<manifest>:<run8>`, setting `migration.run_id`, `test_results.run_id`; visible in `pg_stat_activity`, and in PostgreSQL logs with `log_line_prefix` `%a` (custom parameter group) | `pgtest.sh`, `guard_and_reset.sql`, `test_framework.sql` | auto |
| LOG-07 | Test runs audited: `pgtest.start` (manifest sha256, target host/db/user, IAM auth, application name), `pgtest.end` (exit code, duration, pass/fail counts), `pgtest.refused` | `pgtest.sh` | auto |
| LOG-08 | Troubleshooting: `audit.py tail --run <prefix> --event <prefix>`; Informatica records carry folder, mapping/session, instance, attribute, tag index and SHA-256 of source and converted SQL (lineage), plus OpenLineage events | `audit.py`, `infa_sql_tool.py` | auto |

## AWS services with local fallback (SVC)

| ID | Behaviour | Test |
|---|---|---|
| SVC-01 | Local JSON document store (`logs/state/<collection>.jsonl`): append-only, file-locked, latest version wins, tombstones, compaction; holds lineage events, guardrail results, probe cache, shipping offsets | auto |
| SVC-02 | Configuration: defaults < `.kiro/settings/migration-services.json` (or `MIGRATION_SERVICES_CONFIG`) < `MIGRATION_OFFLINE=1` < `MIGRATION_<CONCERN>_BACKEND=auto|aws|local`; `MIGRATION_LOG_DIR`, `MIGRATION_STATE_DIR` | auto |
| SVC-03 | `auto` without a configured resource → local store, no AWS call | auto |
| SVC-04 | `auto` with a configured resource that is unreachable or denied → local store, `services.fallback` WARN record, probe cached (`probe_cache_seconds`) | auto |
| SVC-05 | `aws` → never silent: missing configuration or failure raises; `services.py status` exits 1 with `UNAVAILABLE` | auto |
| SVC-06 | Audit → Amazon CloudWatch Logs `PutLogEvents`: stream per day/host, chronological batches ≤ 1,000,000 bytes (26-byte overhead per event), ≤ 10,000 events, ≤ 24 h span, files older than 14 days kept locally only, offsets per file (at-least-once) | auto |
| SVC-07 | Lineage → Amazon DataZone `PostLineageEvent` (OpenLineage RunEvent ≤ 300,000 bytes, `--client-token` = local document id for idempotency); pending locally until `sync` succeeds | auto |
| SVC-08 | Guardrail → Amazon Bedrock `ApplyGuardrail` (`source=INPUT`) in chunks with a per-run budget, in addition to the local scan; the `match` value of sensitive-information findings is never stored | auto |
| SVC-09 | Archive → Amazon S3 `PutObject` with `--checksum-algorithm SHA256`, SSE-KMS and optional Object Lock retention; always a local copy with a SHA-256 manifest | auto |
| SVC-10 | Secrets → AWS Secrets Manager: `services.py exec -- <cmd>` (or `PG_SECRET_FROM_SERVICES=1 pgtest.sh`) injects `PG*` variables into the child only; values never printed or logged | auto |
| SVC-11 | `services.py status | probe | sync | show-config (redacted) | guardrail | archive | lineage-emit | exec` | auto |

## Operating notes

- Default is **offline-safe**: with nothing configured every concern resolves to the local store,
  so the skills work on a laptop without AWS. Configure resources in
  `.kiro/settings/migration-services.json` (example: `.kiro/settings/migration-services.example.json`);
  opt-in setup commands and a least-privilege IAM policy are in `references/aws-services.md`.
- Exit codes: `3` = refused by a guardrail (Informatica tool), `4` = refused by the test preflight
  (`pgtest.sh`), `2` = usage/environment.
- Overrides exist for throw-away local clusters only: `PGTEST_ALLOW_SUPERUSER=1`,
  `PGTEST_ALLOW_DANGEROUS=1`. The agent's guard hook blocks setting them.
