# supporting-files

Project-level scripts. Run them from the workspace root.

Every shell script has a PowerShell twin (`.ps1`, Windows PowerShell 5.1+ or PowerShell 7) and a
`.cmd` launcher that takes the same arguments.

| File (Linux / macOS · Windows) | Purpose | Run |
|---|---|---|
| `run_tests.sh` · `run_tests.ps1` / `run_tests.cmd` | Test entry point: project suites, the three skill self-tests, agent hook tests, rule coverage, one run id, AWS sync | `bash supporting-files/run_tests.sh [--project\|--skill]` · `supporting-files\run_tests.cmd [--project\|--skill]` |
| `kiro_migrate.sh` · `kiro_migrate.ps1` / `kiro_migrate.cmd` | Headless batch migration with the agent: scans inputs, converts pending files, runs all tests, archives and syncs evidence | `bash supporting-files/kiro_migrate.sh [source/usp_X.sql …]` · `supporting-files\kiro_migrate.cmd` |
| `package.sh` · `package.ps1` / `package.cmd` → `package.py` | Zip of the workspace **including `.kiro`**. Clears hidden flags, keeps bytes, line endings and executable bits, and verifies the contents | `bash supporting-files/package.sh [--out FILE] [--include-logs]` · `supporting-files\package.cmd` |
| `make_windows_agent.py` | Generates `.kiro/agents/sql-migration-agent-windows.json` from the main agent (`--check` detects drift) | `python3 supporting-files/make_windows_agent.py` |
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
```

Scripts that belong to a skill or to the agent stay inside `.kiro/`, because Kiro loads them from
there and a skill must remain self-contained when copied to another project:

- `.kiro/skills/*/scripts/`: test engine (`pgtest.sh` · `pgtest.ps1` / `pgtest.cmd`, `winlib.ps1`),
  `infa_sql_tool.py`, `migkit`, self-tests (`run_skill_tests.sh` · `.ps1` / `.cmd`).
- `.kiro/agents/hooks/`: guardrail and audit hooks referenced by the agent JSON.
