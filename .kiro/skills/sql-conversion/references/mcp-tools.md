# Optional MCP tools for the sql-conversion skill

The skill works with files and a shell alone. MCP servers make three things faster:
reading source procedures from a live SQL Server, looking up target table definitions,
and checking AWS/Aurora behaviour. Every server below is **optional**. Configure
servers in `.kiro/settings/mcp.json` (IDE and default agent), or in a custom agent's
`mcpServers` block (see `.kiro/agents/sql-migration-agent.json`).

Package names and flags were checked against the awslabs/mcp repository
(September 2026). Most servers run through `uvx`, so install `uv` first:
`brew install uv` or `pip install uv`.

## Which server for which step

| Skill step | Server | Tools used | Read-only? |
|---|---|---|---|
| 1 Read source procedures | `awslabs.mssql-mcp-server` (RDS for SQL Server) | `connect_to_database`, `run_query` | yes by default |
| 1 Target column names/types | `awslabs.postgres-mcp-server` | `connect_to_database`, `get_table_schema` | yes by default |
| 9 Smoke-test on the target | `awslabs.postgres-mcp-server` | `run_query` | writes need `--allow_write_query` |
| 2/5 Check AWS behaviour, versions, extensions | AWS Knowledge (remote) | `search_documentation`, `read_documentation`, `get_regional_availability` | yes |
| same, offline-friendly alternative | `awslabs.aws-documentation-mcp-server` | `search_documentation`, `read_documentation`, `recommend` | yes |
| Inspect clusters, versions, parameters | `awslabs.aws-api-mcp-server` | `call_aws`, `suggest_aws_commands` | set `READ_OPERATIONS_ONLY=true` |
| Run the test suite | — | use the shell: suites need psql meta-commands (`\ir`, `\if`) | — |

## Configuration snippets

### PostgreSQL / Aurora target: `awslabs.postgres-mcp-server`
```json
"awslabs.postgres-mcp-server": {
  "command": "uvx",
  "args": ["awslabs.postgres-mcp-server@latest", "--privilege_check", "enforce"],
  "env": { "AWS_PROFILE": "default", "AWS_REGION": "us-east-1", "FASTMCP_LOG_LEVEL": "ERROR" },
  "disabled": false,
  "autoApprove": ["get_table_schema", "is_database_connected"]
}
```
- **Connect at runtime.** Ask the agent, for example: *"Connect to database `my_test_db`
  on Aurora PostgreSQL cluster `my-cluster` (endpoint `…`, port 5432) in us-east-1 using
  `pgwire_iam`"*. The tool `connect_to_database` takes region, database type, connection
  method (`pgwire`, `pgwire_iam` for Aurora, `rdsapi`), cluster identifier, endpoint,
  port and database.
- **Connect at startup instead:** add `--connection_method PG_WIRE_IAM_PROTOCOL
  --db_type APG --db_cluster_arn <arn> --db_endpoint <host> --database <db> --region <r>`.
- **Read-only unless `--allow_write_query` is passed** (a best-effort check). Keep it
  read-only. The converted code goes into the database through the test runner, not
  through chat.
- `--privilege_check enforce` refuses to start with a superuser credential.
- Flags that do **not** exist in the current code, despite some READMEs: `--resource_arn`,
  `--readonly`, `--hostname`, `--connection-string`.

### SQL Server source: `awslabs.mssql-mcp-server` (Amazon RDS for SQL Server)
```json
"awslabs.mssql-mcp-server": {
  "command": "uvx",
  "args": ["awslabs.mssql-mcp-server@latest",
           "--connection_method", "MSSQL_PASSWORD",
           "--instance_identifier", "<rds-instance-id>",
           "--db_endpoint", "<host>", "--region", "us-east-1", "--database", "<SourceDb>"],
  "env": { "AWS_PROFILE": "default", "FASTMCP_LOG_LEVEL": "ERROR" },
  "disabled": false,
  "autoApprove": []
}
```
- Credentials come from AWS Secrets Manager; the server is read-only by default.
- Its query filter blocks `sp_*` calls, so use the catalog instead of `sp_helptext`:
  ```sql
  SELECT OBJECT_SCHEMA_NAME(m.object_id) AS schema_name, OBJECT_NAME(m.object_id) AS name, m.definition
  FROM   sys.sql_modules m
  JOIN   sys.objects o ON o.object_id = m.object_id
  WHERE  o.type IN ('P', 'FN', 'IF', 'TF', 'TR', 'V')
  ORDER  BY 1, 2;
  ```
  Save each definition to `source/<Name>.sql` before converting, so the conversion is
  reproducible. Table DDL: script it with SSMS or `mssql-scripter` into `source/schema/`.
- Not on RDS? Export the scripts from SSMS ("Generate Scripts") or use `sqlcmd` in the shell.

### AWS Knowledge (remote, no install, no credentials)
```json
"aws-knowledge": { "url": "https://knowledge-mcp.global.api.aws", "type": "http", "disabled": false }
```
It is rate-limited. Use it to confirm version availability (e.g. "is Aurora PostgreSQL 17
available in eu-west-1?") and documented behaviour.

### AWS documentation (local)
```json
"awslabs.aws-documentation-mcp-server": {
  "command": "uvx",
  "args": ["awslabs.aws-documentation-mcp-server@latest"],
  "env": { "AWS_DOCUMENTATION_PARTITION": "aws", "FASTMCP_LOG_LEVEL": "ERROR" },
  "disabled": false
}
```

### AWS API (read-only)
```json
"awslabs.aws-api-mcp-server": {
  "command": "uvx",
  "args": ["awslabs.aws-api-mcp-server@latest"],
  "env": { "AWS_REGION": "us-east-1", "READ_OPERATIONS_ONLY": "true" },
  "disabled": false
}
```
Useful for `aws rds describe-db-clusters` (engine version, IAM auth enabled). Generate
IAM database tokens in the shell (`aws rds generate-db-auth-token`), not through MCP.

## Safety rules for agents using these servers

1. Read-only by default. Never add `--allow_write_query` or remove `READ_OPERATIONS_ONLY`
   without the user asking.
2. Connect only to databases whose names mark them as test/dev/sandbox for anything that
   writes. Production sources are read through `sys.sql_modules` only.
3. `autoApprove` only for read tools (`get_table_schema`, `is_database_connected`,
   documentation search). Queries stay approval-gated.
4. **Do not install look-alike packages.** The PyPI package `awslabs.aws-dms-mcp-server`
   is **not** published by AWS (its description says it was created "for security
   research"). There is no official AWS DMS MCP server in awslabs/mcp. Reach DMS through
   `awslabs.aws-api-mcp-server` or the console.
5. Kiro only expands `${VAR}` in `env` for variables you have approved. Never put
   passwords in `mcp.json`: use AWS profiles, IAM auth or Secrets Manager.

## Kiro CLI commands (checked against Kiro CLI 2.21)

| Task | Command |
|---|---|
| List servers | `kiro-cli mcp list` (all), `kiro-cli mcp list workspace` / `global` / `default` |
| Show one server | `kiro-cli mcp status --name <server>` |
| Add or switch on (workspace `mcp.json`) | `kiro-cli mcp add --scope workspace --name <server> --command uvx --args '["pkg@latest","--flag","value"]' --env KEY=VALUE --force` |
| Add a remote server | `kiro-cli mcp add --scope workspace --name aws-knowledge --url https://knowledge-mcp.global.api.aws --force` |
| Switch off | same `add` command with `--disabled`, or `"disabled": true` in the JSON |
| Remove | `kiro-cli mcp remove --scope workspace --name <server>` |
| Import | `kiro-cli mcp import --file other-mcp.json workspace` |
| In chat | `/mcp` (servers and tools), `/tools` (permissions), `/tools trust <tool>` |

- Use JSON-array `--args` when an argument starts with `--`.
- `kiro-cli mcp add --agent <name>` rewrites the whole agent file. It inlines a `file://`
  prompt and drops fields the v2 schema does not know, such as `permissions`. For agents
  with a prompt file or v3 permissions, edit the agent JSON instead.

## Kiro specifics

- The workspace `.kiro/settings/mcp.json` wins over the user-level
  `~/.kiro/settings/mcp.json`; an agent's own `mcpServers` wins over both.
- A custom agent loads the workspace `mcp.json` only if `"includeMcpJson": true`.
  Kiro Crew's generated agent sets it to `false`, so under Crew, put the servers in the
  agent file.
- A tool is referenced as `@<server>/<tool>` in an agent's `tools` / `allowedTools`
  (e.g. `@awslabs.postgres-mcp-server/get_table_schema`).
