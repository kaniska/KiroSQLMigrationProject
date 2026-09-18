# Agent guardrail and audit hooks (sql-migration-agent, sql-migration-agent-windows)

Kiro runs these hooks outside the model. Instructions hidden in a source file, an XML export or a
pasted script therefore cannot talk the agent past them. `guard_tool.py` (`preToolUse`) exits with
code 2 to block a tool call and returns the reason on stderr to the agent; any internal error also
blocks (fail closed). `audit_event.py` (`agentSpawn`, `userPromptSubmit`, `postToolUse`, `stop`)
writes correlated audit records and never breaks the session. Tests: `tests/test_hooks.py`; the
coverage check fails if a row has no test.

Kiro already refuses agent writes to `.kiro/settings/`; these hooks add the rest. They complement,
not replace, the agent's `allowedTools` / `toolsSettings` / `permissions` allow-lists, IAM least
privilege for the AWS credentials the session uses, and the database role without superuser.

## Guard rules (preToolUse)

| ID | Blocks | Test |
|---|---|---|
| GRD-01 | Credential access: `~/.aws`, `aws configure get/export-credentials`, `printenv`/`env`, echoing secret variables, keychain reads, instance metadata `169.254.169.254`, `secretsmanager` calls, reading `.pem`/`id_rsa`/`.env`/`.pgpass`/`.netrc`/`.ssh`, Kiro session stores | auto |
| GRD-02 | Remote code execution and exfiltration: `curl … | sh`, uploads with `curl -d/-F/-T`, `wget --post`, `nc`/`socat`/`telnet`, `scp`/`sftp`/`rsync host:`, `base64 -d | sh` | auto |
| GRD-03 | Destructive commands: `rm -rf` on the workspace or key folders, `git push/reset --hard/clean -f`, `sudo`, `chmod 777`, `mkfs`, `dd` | auto |
| GRD-04 | Tampering with guardrails, configuration or audit: shell writes/moves/deletes under `.kiro/steering|agents|skills|settings|hooks`, `logs/audit`, the session file; changing `MIGRATION_*` backends, offline mode, log dir; setting `PGTEST_ALLOW_*`; file-tool writes to those paths or `.git/` | auto |
| GRD-05 | AWS changes: any `aws <service> create-|delete-|put-|update-|modify-|attach-|tag-|start-|stop-|invoke-|post-…`, `aws s3 cp/mv/rm/sync/mb/rb`; MCP servers asked for write mode | auto |
| GRD-06 | Databases that are not test databases (`dbname=`, `-d`, `PGDATABASE=`, URIs) and critical SQL (`COPY … PROGRAM`, `ALTER SYSTEM`, role changes …) in psql commands or MCP queries; the same database-name rule for the skill tools that reach Amazon Redshift, Athena and Glue (`redshift_tool.py run --database`, `iceberg_tool.py run --database`, `schema_tool.py snapshot --glue --database`) | auto |
| GRD-07 | Package installation (`pip`, `npm`, `brew`, `apt`, `gem`) — ask the user | auto |
| GRD-08 | Starting agents with every tool trusted (`--trust-all-tools`, `/tools trust-all`) | auto |
| GRD-09 | File writes outside the workspace | auto |
| GRD-10 | Writing content that carries prompt injection (SEC-01), hidden characters (SEC-02) or credentials (SEC-03) | auto |
| GRD-11 | Writing critical PostgreSQL constructs (SEC-04) into converted code (`generated/`, `source/`); tests and references may mention them | auto |
| GRD-12 | Applying schema-change patches to a live target (`change_tool.py patch --apply`): the kit only produces dry-run packages (`PRODUCTION_WRITE_DENIED`); deployment goes through the normal release path | auto |

## Audit hooks

| ID | Behaviour | Test |
|---|---|---|
| HOOK-01 | `agentSpawn`: new session run id in `logs/state/current_session.json` (all tools started by the session inherit it), `session.start` record, security notice in the agent context listing SEC-01/02/03/06 findings in `source/` and `generated/` | auto |
| HOOK-02 | `userPromptSubmit`: logs prompt length and SHA-256 only (never the text); warns the agent when the prompt carries injection, hidden characters or credentials | auto |
| HOOK-03 | `postToolUse` / `preToolUse` decisions: tool name, redacted and length-capped input (file contents as length + SHA-256), outcome; `guard.allowed` / `guard.blocked` with the rule id | auto |
| HOOK-04 | `stop`: `session.stop` record and a background `services.py sync` (CloudWatch Logs / DataZone when configured); hook errors are logged as `hook.error` and never fail the session | auto |
| HOOK-05 | Cross-platform parity: every `.sh` has a PowerShell `.ps1` twin and a `.cmd` launcher (LF / CRLF / UTF-8 BOM as each platform needs); `sql-migration-agent-windows.json` is generated from the agent (same tools, resources, write paths, MCP servers and hooks; `python -X utf8` and `.cmd` commands) and checked for drift; guard rules also match PowerShell and cmd.exe forms | auto |
