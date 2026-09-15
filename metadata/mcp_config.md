# Database access and MCP servers (project notes)

Generic MCP guidance (which server for which skill step, verified packages and flags,
safety rules) lives with the skill:
**`.kiro/skills/sql-conversion/references/mcp-tools.md`**. This page only records this
project's setup.

## How this project reaches the database

| Need | Path | Status |
|---|---|---|
| Run all tests | `bash supporting-files/run_tests.sh` (shell) | working: 405/405 on Aurora PostgreSQL 17.7 (2026-09-10) |
| Ad-hoc queries, schema lookup, docs | MCP servers in `.kiro/settings/mcp.json` and in `.kiro/agents/sql-migration-agent.json` | configured, **disabled** until `uv` is installed |

The suites use psql meta-commands (`\ir`, `\if`, `\gset`), so they run through the shell,
never through an MCP `run_query` tool.

## Test database

| Setting | Value (see `metadata/test_connection.env`) |
|---|---|
| Cluster endpoint | `database-1.cluster-ck1imm86sh9q.us-east-1.rds.amazonaws.com` (Aurora PostgreSQL 17.7) |
| Database / user | `sql_migration_test` / `migration_agent` (non-superuser) |
| Authentication | IAM database authentication only; 15-minute tokens generated per run by `aws rds generate-db-auth-token` |
| TLS | `sslmode=require` (`verify-full` + RDS CA bundle for stricter checking) |
| One-time setup | `metadata/create_agent_user.sql` (already applied) |

## Enabling the MCP servers

1. `brew install uv`
2. In `.kiro/settings/mcp.json` (IDE / default agent) and/or in the agent's `mcpServers`, set
   `"disabled": false` on the servers you want:
   - `awslabs.postgres-mcp-server`: read-only target inspection (`get_table_schema`)
   - `aws-knowledge`: remote AWS documentation, no install needed
   - `awslabs.aws-documentation-mcp-server`: local AWS documentation search
   - `awslabs.mssql-mcp-server`: read procedure definitions from an RDS for SQL Server source
     (replace the `<…>` placeholders first)
   - `awslabs.aws-api-mcp-server`: read-only AWS API (`describe-db-clusters`)
3. Connect the PostgreSQL server from chat:
   > Connect to database `sql_migration_test` on Aurora PostgreSQL cluster `database-1`
   > (endpoint `database-1.cluster-ck1imm86sh9q.us-east-1.rds.amazonaws.com`, port 5432)
   > in us-east-1 using `pgwire_iam`.

Kiro Crew's generated agent ignores workspace `mcp.json` (`includeMcpJson: false`). Use the
`sql-migration-agent`, which declares its own servers.

## Letting Kiro run the tests without asking each time

- **`sql-migration-agent`:** already pre-approves `bash supporting-files/run_tests.sh …` (`toolsSettings`
  for CLI 2.x, `permissions` for CLI 3 / IDE 1.0).
- **Default agent, Kiro IDE 1.0+:** add to `~/.kiro/settings/permissions.yaml`:
  ```yaml
  rules:
    - capability: shell
      match: ["bash supporting-files/run_tests.sh*"]
      effect: allow
  ```
- **Kiro CLI:** `/tools trust` for the shell tool, or run the agent above.

## Security notes

- The AWS identity on this machine is the account **root** user. Create an IAM user or role
  limited to `rds-db:connect` on `dbuser:<cluster-resource-id>/migration_agent` and use that
  profile instead.
- The test engine drops only objects that the connected role owns in schema `public`, and
  refuses database names without `test`/`dev`/`sandbox`/`local`.
- No passwords are stored anywhere in the project.
