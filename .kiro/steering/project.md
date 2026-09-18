---
inclusion: always
---

# Project settings — SQLMigrationProject

Project-specific values that complete the generic rules in `migration.md`.
Copy the rules and the skill to another workspace, then write that workspace's own
version of this file.

## Target

| Setting | Value |
|---|---|
| Target engine | **Aurora PostgreSQL 17.7**. PostgreSQL 17 features are allowed (MERGE `BY SOURCE`, `RETURNING merge_action()`, MERGE in `WITH`) |
| Target schema | `public` |
| Test database | `sql_migration_test` on cluster `database-1` (us-east-1). The test engine refuses databases whose names lack `test`/`dev`/`sandbox`/`local`, and superuser sessions |
| AWS services | None configured yet: audit, lineage, guardrail, archive and secrets all use the local store (`logs/`). Creating them is a user decision; see `.kiro/skills/sql-conversion/references/aws-services.md` |
| Database user | `migration_agent` (IAM database authentication only; 15-minute tokens) |
| Connection defaults | `metadata/test_connection.env` (no secrets) |

## Layout

| Path | Contents |
|---|---|
| `source/*.sql` | SQL Server procedures to migrate (`source/schema/` = T-SQL DDL) |
| `generated/*.sql` | Converted code; `generated/schema.sql` = converted DDL |
| `examples/` | Reference pair for newcomers (`source_example.sql` ↔ `converted_example.sql`) |
| `tests/test_runner.sql` | Project test manifest: schema → seed → converted files → suites |
| `tests/test_cases.sql` | Project suites (one per converted routine) |
| `tests/seed_data.sql` | Deterministic data with fixed dates |
| `metadata/migration_log.json` | Per-object status, manual-review flags, last test run |
| `logs/audit/audit-YYYYMMDD.jsonl` | Hash-chained audit records (all tools, hooks, test runs), one correlation `run_id` per run |
| `logs/state/` | Local JSON store: lineage events, guardrail results, shipping offsets, agent session |
| `.kiro/settings/migration-services.json` | Optional AWS resources for audit/lineage/guardrail/archive/secrets (example: `migration-services.example.json`); absent → local only |

## Commands

| Task | Linux / macOS | Windows |
|---|---|---|
| All tests (project suites + the eight skill self-tests + hooks + rule coverage) | `bash supporting-files/run_tests.sh` | `supporting-files\run_tests.cmd` |
| Project suites only | `bash supporting-files/run_tests.sh --project` | `supporting-files\run_tests.cmd --project` |
| Skill self-tests only | `bash supporting-files/run_tests.sh --skill` | `supporting-files\run_tests.cmd --skill` |
| One skill | `bash .kiro/skills/<skill>/scripts/run_skill_tests.sh` | `.kiro\skills\<skill>\scripts\run_skill_tests.cmd` |
| Package the workspace (zip with .kiro) | `bash supporting-files/package.sh` | `supporting-files\package.cmd` |

On Windows use the agent `sql-migration-agent-windows` and `python` instead of `python3` in the commands below.

| Task | Command |
|---|---|
| Local PostgreSQL 17 instead of Aurora | `TEST_TARGET=local PGUSER=postgres bash supporting-files/run_tests.sh` |
| Where do audit/lineage go (AWS or local)? | `python3 .kiro/skills/sql-conversion/scripts/migkit/services.py status` |
| Everything one run did | `python3 .kiro/skills/sql-conversion/scripts/migkit/audit.py tail --run <run8>` |
| Scan an input before converting | `python3 .kiro/skills/sql-conversion/scripts/migkit/security.py scan <file>` |
| Assess and route objects (target undecided) | `python3 .kiro/skills/migration-assessment/scripts/assess_tool.py assess source --consumer app --out generated/assessment` |
| Compare source and converted schema | `python3 .kiro/skills/schema-conformance/scripts/schema_tool.py snapshot source/schema --dialect tsql --out generated/schema/source.snapshot.json` then `… snapshot generated/schema.sql --dialect pgsql …` and `… compare … --profile aurora --out generated/schema/compare` |
| Regenerate Windows twins after editing a runner | `python3 supporting-files/make_skill_runners.py` and `python3 supporting-files/make_windows_agent.py` |

After converting a file: add its `\ir` line to `tests/test_runner.sql`, add a suite to
`tests/test_cases.sql`, update `metadata/migration_log.json`, then run
`bash supporting-files/run_tests.sh`.

## Skills in this workspace

| Skill | Ask for | Example prompt |
|---|---|---|
| `sql-conversion` | T-SQL procedures/functions/triggers/DDL → PL/pgSQL | "Convert source/usp_X.sql" |
| `sql-reporting` | report / dashboard / KPI SQL on the converted schema | "Monthly revenue by category for 2025 with YoY growth" |
| `informatica-etl-conversion` | PowerCenter XML exports with SQL Server SQL | "Convert source/informatica/wf_orders.xml for PostgreSQL" |
| `migration-assessment` | inventory, placement (M2RVE), complexity, target candidates, which skill | "Assess source/ for a BI migration — which objects belong on Redshift?" |
| `sql-conversion-redshift` | tables, BI edge views, set-based loads → Amazon Redshift | "Convert source/schema/sales_db_schema.sql to Redshift with design metadata/design/redshift.json" |
| `sql-conversion-iceberg` | tables, loads, Athena views, Glue jobs → Iceberg on S3 | "Land dbo.FactSales as an Iceberg table partitioned by day(SaleDate); generate the Glue MERGE job" |
| `schema-conformance` | snapshot + compare + conform + reference check | "Compare source/schema with generated/schema.sql and list every conflict" |
| `schema-change-propagation` | rename/cast change templates through the target flow | "Apply metadata/changes/q3_renames.csv to generated/ as a dry run" |

Reporting SQL runs against `generated/schema.sql`; Informatica conversions go to
`generated/informatica/`; Redshift, Iceberg, assessment, schema and change packages go to
`generated/redshift/`, `generated/iceberg/`, `generated/assessment/`, `generated/schema/` and
`generated/changes/`. Design decisions (`*.design.json`), naming mappings and change templates
live under `metadata/design/`, `metadata/schema/` and `metadata/changes/`. **Targets in this
workspace:** Aurora PostgreSQL 17.7 is the primary target (tested against `sql_migration_test`);
Amazon Redshift and Iceberg/Athena have no test resources configured — their tools run
statically and through the stub AWS CLI until `REDSHIFT_DATABASE`/`REDSHIFT_WORKGROUP` or
`ATHENA_DATABASE` point at test resources (never created by the kit).

## Agent and tools

- Agent for end-to-end migration: `.kiro/agents/sql-migration-agent.json`
  (`kiro-cli chat --agent sql-migration-agent`; Windows: `sql-migration-agent-windows`). The agent
  routes each request to a skill after the intake questions in `.kiro/agents/prompts/examples.md`.
- Optional MCP servers (PostgreSQL, AWS documentation, AWS Knowledge, SQL Server
  source) are described in `.kiro/skills/sql-conversion/references/mcp-tools.md`. They are
  wired, but disabled, in `.kiro/settings/mcp.json` and in the agent.
