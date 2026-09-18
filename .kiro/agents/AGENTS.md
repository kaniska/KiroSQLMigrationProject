# Agents: sql-migration-agent and sql-reporting-agent

Two Kiro agents ship with the kit, each with a generated Windows twin (`*-windows.json`, same
tools, resources, write paths, MCP servers and hooks; `python -X utf8` and `.cmd` commands):

| Agent | Purpose | Skills it loads | Writes only under |
|---|---|---|---|
| `sql-migration-agent` | **SQL conversion assistant** — routes SQL Server object migration (standalone SQL and Informatica-embedded SQL) to Aurora PostgreSQL, Amazon Redshift or Iceberg on S3; assessment, schema conformance, change propagation | all eight `SKILL.md` files (`skill://.kiro/skills/*/SKILL.md`) | `generated/**`, `tests/**`, `metadata/{migration_log.json,design,schema,changes}/`, `source/schema/**`, `source/informatica/**` |
| `sql-reporting-agent` | **Reporting SQL assistant** — report, dashboard, KPI and analytics SQL on PostgreSQL, Redshift, Athena/Iceberg or Spark; reviews dashboard queries; grounds names in read-only schema snapshots | `sql-reporting`, `schema-conformance` (read-only commands), `sql-conversion-redshift` and `sql-conversion-iceberg` (`check`/`run` only) | `generated/reports/**`, `generated/schema/**`, `tests/**` |

Both run the same hooks (`guard_tool.py` preToolUse, `audit_event.py` for the session lifecycle,
`migration_status.py` at spawn) and the same guardrails (`GUARDRAILS.md`, `GRD-01…12`).

## Run and test them from Kiro

```bash
kiro-cli agent list                                                     # both agents listed as "Workspace"
kiro-cli agent validate --path .kiro/agents/sql-migration-agent.json   # no output = valid (repeat for the other three files)
kiro-cli chat --agent sql-migration-agent                               # conversion assistant (Windows: sql-migration-agent-windows)
kiro-cli chat --agent sql-reporting-agent                               # reporting assistant  (Windows: sql-reporting-agent-windows)
kiro-cli chat --no-interactive --agent sql-reporting-agent "Monthly revenue by category for 2025 with YoY growth on PostgreSQL"
bash supporting-files/verify_agents.sh [--smoke]                        # structural tests + kiro-cli validate (+ one headless prompt per agent)
```
In the IDE: agent selector → `sql-migration-agent` or `sql-reporting-agent`; skills via `/skill-name`;
`/context show` lists what is loaded. Prompts per skill: `prompts/examples.md`.

## Agent rules (proven by `hooks/tests/test_agents.py`, tags `[AG-nn]`)

| ID | Rule | Test |
|---|---|---|
| AG-01 | every agent file parses; `name` equals the file stem; the prompt file exists and is non-trivial; a welcome message names example prompts | auto |
| AG-02 | every `resources` entry resolves to at least one existing file (`file://` globs, `skill://` SKILL.md paths); every hook command points at an existing script | auto |
| AG-03 | every representative command of the agent's workflow (from `prompts/examples.md` and its SKILL.md files) matches an `allowedCommands` regex and a `permissions` shell glob; every regex compiles | auto |
| AG-04 | write scope is bounded: no `allowedPaths` under `.kiro/`, `logs/`, `metadata/test_connection.env` or outside the workspace; MCP servers are `disabled` by default; the JSON carries no credentials | auto |
| AG-05 | separation of concerns: the reporting agent cannot run conversion, injection, change patching or migration-log writes; the migration agent can; both share the guard and audit hooks | auto |
| AG-06 | Windows twins are generated and in sync (`make_windows_agent.py --check`), keep the same hooks and write paths, and use `python -X utf8` / `.cmd` commands | auto |
| AG-07 | `kiro-cli agent validate` accepts all four agent files when `kiro-cli` is installed (recorded as "not installed" otherwise, never as a pass) | auto |
| AG-08 | the routing prompt names every skill that exists and no skill that does not; `examples.md` has a section per skill | auto |
