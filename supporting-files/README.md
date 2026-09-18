# supporting-files

Project-level scripts. Run them from the workspace root.

Every shell script has a PowerShell twin (`.ps1`, Windows PowerShell 5.1+ or PowerShell 7) and a
`.cmd` launcher that takes the same arguments.

| File (Linux / macOS · Windows) | Purpose | Run |
|---|---|---|
| `run_tests.sh` · `run_tests.ps1` / `run_tests.cmd` | Test entry point: project suites, the eight skill self-tests, agent hook tests, agent structural tests, MCP placeholder tests, rule coverage, one run id, AWS sync | `bash supporting-files/run_tests.sh [--project\|--skill]` · `supporting-files\run_tests.cmd [--project\|--skill]` |
| `kiro_migrate.sh` · `kiro_migrate.ps1` / `kiro_migrate.cmd` | Headless batch migration with the agent: scans inputs, converts pending files, runs all tests, archives and syncs evidence | `bash supporting-files/kiro_migrate.sh [source/usp_X.sql …]` · `supporting-files\kiro_migrate.cmd` |
| `package.sh` · `package.ps1` / `package.cmd` → `package.py` | Zip of the workspace **including `.kiro`**. Clears hidden flags, keeps bytes, line endings and executable bits, and verifies the contents | `bash supporting-files/package.sh [--out FILE] [--include-logs]` · `supporting-files\package.cmd` |
| `verify_agents.sh` · `verify_agents.ps1` / `verify_agents.cmd` | Verifies both agents: structural tests (AG-01..08), `kiro-cli agent validate` for all four files, workspace listing; `--smoke` runs one read-only headless prompt per agent | `bash supporting-files/verify_agents.sh [--smoke]` · `supporting-files\verify_agents.cmd [--smoke]` |
| `make_windows_agent.py` | Generates the `-windows.json` twin of every agent (`sql-migration-agent`, `sql-reporting-agent`) from the main agent files (`--check` detects drift) | `python3 supporting-files/make_windows_agent.py` |
| `mcp/kit_mcp_server.py` | Placeholder MCP server exposing the read-only kit tools (assess, check, compare, toolbox, audit) over stdio; `mcp/README.md` (MCP-01..04), `mcp/tests/` | `python3 supporting-files/mcp/kit_mcp_server.py --list` |
| `check_windows_readiness.py` | Static Windows readiness check (HOOK-06): every `.sh` has a BOM/CRLF `.ps1` twin and `.cmd` launcher, balanced PowerShell syntax, references resolve, no drift between hand-written twins and their `.sh`, generators and Windows agents in sync, `mcp.json` Windows variants | `python3 supporting-files/check_windows_readiness.py` |
| `make_skill_runners.py` | Generates `run_skill_tests.ps1` / `.cmd` for every skill that declares `scripts/skill.runner.json` (Python-only self-tests: assessment, Redshift, Iceberg, schema conformance, change propagation); `--check` detects drift | `python3 supporting-files/make_skill_runners.py` |
| `doc-generators/make_quickref.js` | Builds the one-page `docs/SQLMigrationProject_Quick_Reference.docx` | see below |
| `doc-generators/make_guide.js` | Builds `docs/SQL_Migration_User_Guide.docx` | see below |
| `doc-generators/make_reporting_guide.js` | Builds `docs/Reporting_Analytics_SQL_User_Guide.docx` | see below |
| `doc-generators/make_architecture.js` | Builds `docs/Technical_Architecture.docx` | see below |
| `doc-generators/make_deck.js` | Builds `docs/Executive_Overview.pptx` (editable shapes); an optional slide number builds only that slide | see below |

Rebuild the documents (needs Node.js with the `docx` and `pptxgenjs` npm packages):

```bash
export NODE_PATH=$(npm root -g)
node supporting-files/doc-generators/make_guide.js docs/SQL_Migration_User_Guide.docx
node supporting-files/doc-generators/make_reporting_guide.js docs/Reporting_Analytics_SQL_User_Guide.docx
node supporting-files/doc-generators/make_architecture.js docs/Technical_Architecture.docx
node supporting-files/doc-generators/make_deck.js docs/Executive_Overview.pptx
node supporting-files/doc-generators/make_quickref.js docs/SQLMigrationProject_Quick_Reference.docx
```

Scripts that belong to a skill or to the agent stay inside `.kiro/`, because Kiro loads them from
there and a skill must remain self-contained when copied to another project:

- `.kiro/skills/*/scripts/`: test engine (`pgtest.sh` · `pgtest.ps1` / `pgtest.cmd`, `winlib.ps1`),
  `infa_sql_tool.py`, `assess_tool.py`, `redshift_tool.py`, `iceberg_tool.py`, `schema_tool.py`, `change_tool.py`,
  `migkit` (security, audit, localdb, services, contract, ddl), self-tests (`run_skill_tests.sh` · `.ps1` / `.cmd`).
- `.kiro/agents/hooks/`: guardrail and audit hooks referenced by the agent JSON.
