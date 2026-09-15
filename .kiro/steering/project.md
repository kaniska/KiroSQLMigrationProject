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
| All tests (project suites + the three skill self-tests + hooks + rule coverage) | `bash supporting-files/run_tests.sh` | `supporting-files\run_tests.cmd` |
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

After converting a file: add its `\ir` line to `tests/test_runner.sql`, add a suite to
`tests/test_cases.sql`, update `metadata/migration_log.json`, then run
`bash supporting-files/run_tests.sh`.

## Skills in this workspace

| Skill | Ask for | Example prompt |
|---|---|---|
| `sql-conversion` | T-SQL procedures/functions/triggers/DDL → PL/pgSQL | "Convert source/usp_X.sql" |
| `sql-reporting` | report / dashboard / KPI SQL on the converted schema | "Monthly revenue by category for 2025 with YoY growth" |
| `informatica-etl-conversion` | PowerCenter XML exports with SQL Server SQL | "Convert source/informatica/wf_orders.xml for PostgreSQL" |

Reporting SQL runs against `generated/schema.sql`; Informatica conversions go to
`generated/informatica/`.

## Agent and tools

- Agent for end-to-end migration: `.kiro/agents/sql-migration-agent.json`
  (`kiro-cli chat --agent sql-migration-agent`).
- Optional MCP servers (PostgreSQL, AWS documentation, AWS Knowledge, SQL Server
  source) are described in `.kiro/skills/sql-conversion/references/mcp-tools.md`. They are
  wired, but disabled, in `.kiro/settings/mcp.json` and in the agent.
