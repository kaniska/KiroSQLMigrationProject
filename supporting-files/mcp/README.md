# Kit MCP server (placeholder / preview)

`kit_mcp_server.py` exposes the kit's **read-only and dry-run** skill tools as an MCP server so
other agents, IDEs and pipelines can call them without a Kiro session. It is a placeholder for the
roadmap item "expose the skills as MCP": the protocol, the audit trail and the allow-list are real;
packaging, resources and prompts are not done yet.

| | |
|---|---|
| Transport | stdio, JSON-RPC 2.0, newline-delimited messages (`initialize`, `tools/list`, `tools/call`, `ping`) |
| Tools | `assess_object` · `check_sql` (redshift / athena / spark / report:*) · `compare_schemas` · `toolbox` · `audit_tail` |
| Never exposed | executing on a database or warehouse, applying change patches, injecting XML, writing conversions — those stay behind the agents' guardrails |
| Register | `.kiro/settings/mcp.json` → `sqlmigration-kit` (`"disabled": true` until you enable it); any MCP client: `python3 supporting-files/mcp/kit_mcp_server.py` |
| Try | `python3 supporting-files/mcp/kit_mcp_server.py --list` · `printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}' '{"jsonrpc":"2.0","id":2,"method":"tools/list"}' \| python3 supporting-files/mcp/kit_mcp_server.py` |
| Test | `python3 supporting-files/mcp/tests/test_mcp_server.py` (also part of `run_tests.sh`) |

## Rules (proven by `tests/test_mcp_server.py`, tags `[MCP-nn]`)

| ID | Rule | Test |
|---|---|---|
| MCP-01 | the server answers `initialize` with its protocol version, capabilities and name, ignores `notifications/initialized`, answers `ping`, and returns `-32601` for unknown methods and `-32700` for bad JSON | auto |
| MCP-02 | `tools/list` returns the catalog with JSON schemas; every tool maps to an existing kit CLI and only to read-only or dry-run sub-commands | auto |
| MCP-03 | `tools/call` runs the CLI inside the workspace, returns its output as text with `isError` and the exit code, and writes an audit record under the run id | auto |
| MCP-04 | arguments are validated against the schema: unknown tools or arguments, enum violations, absolute or `..` paths, missing files and non-hex run ids are refused (audited, `isError`) — nothing is executed | auto |

## Roadmap

- Package as `uvx sqlmigration-kit-mcp` with per-tool schemas generated from the CLI parsers.
- MCP **resources** for the catalogs (`corner-cases.md`, `dialects.md`, `governance.md`) and **prompts** for the intake questions.
- Optional write tools (convert, package) gated by the same guard rules as the agents (`GRD-nn`) and a per-call approval.
- AI-DLC integration: expose assessment / conversion packages as units of work.
