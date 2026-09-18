---
name: sql-conversion-redshift
description: Convert SQL Server objects (tables, BI edge views, set-based load procedures, ETL SQL) to Amazon Redshift - approved datatype map, DISTSTYLE/SORTKEY design decisions, informational constraints, PL/pgSQL procedures with Redshift limits (INOUT refcursor results, atomic transactions, MERGE restrictions), late-binding views, RLS/masking policy drafts, static Redshift review, rule ledger, and execution evidence through the Redshift Data API on test databases only. Use when the approved target is Amazon Redshift (RA3 or Serverless), when asked to convert T-SQL to Redshift SQL, or to check hand-written Redshift SQL for residual SQL Server constructs.
license: Apache-2.0
metadata:
  version: "1.0"
  target: "Amazon Redshift (RA3 / Serverless), SQL surface as of 2026"
  gates: "G4 generation, G5 static validation, G6 execution evidence of the seven-gate governance workflow"
---

# SQL Server → Amazon Redshift conversion

Redshift is an analytical warehouse. This skill converts **what belongs there** — curated tables,
BI edge views, set-based loads — and refuses to emulate what does not (triggers, cursors, table
functions), routing those objects back to `migration-assessment`. Rules: `.kiro/steering/redshift.md`
(`[R-1]…[R-15]`) and `.kiro/steering/governance.md`. Corner cases: `references/corner-cases.md`
(`RS-01…RS-70`, every row proven by a tagged test). Worked pairs: `references/examples/`
(`*.sqlserver.sql` → `*.redshift.sql`, design decisions in `*.design.json`).

`scripts/redshift_tool.py` is deterministic standard-library Python (shared engine: the
`sql-conversion` skill's `migkit`). The model translates procedural logic and explains; the tool
converts DDL, lints the result, infers the ledger, executes on a test database and packages.

## Procedure

### Step 0: Confirm placement
The request must carry `target.platform = Redshift` from `migration-assessment`. If the object is
`L4` or has Redshift blockers (cursor loops, triggers, table functions) stop with
`TARGET_DECISION_REQUIRED` and explain the alternative (Aurora PostgreSQL via `sql-conversion`).

### Step 1: Tables — convert DDL with a design decision
```bash
python3 .kiro/skills/sql-conversion-redshift/scripts/redshift_tool.py convert-ddl source/schema/tables.sql --design design.json --out generated/redshift/tables.sql --ledger generated/redshift/tables.ledger.json
```
`design.json` (optional) fixes the warehouse design per table; without it every table gets
`DISTSTYLE AUTO` / `SORTKEY AUTO` and a ledger row asking for the decision — never an invented
distribution key [RS-30]:
```json
{"schema": "sales", "tables": {"dbo.FactSales": {"diststyle": "KEY", "distkey": "CustomerKey", "sortkey": ["SaleDate"]},
                               "dbo.DimCustomer": {"diststyle": "ALL", "sortkey": ["CustomerKey"]}}}
```
What the converter does: approved type map (`NVARCHAR` bytes, `MAX` → `VARCHAR(65535)`,
`MONEY` → `DECIMAL(19,4)`, `BIT` → `BOOLEAN`, `UNIQUEIDENTIFIER` → `VARCHAR(36)`, `DATETIME` →
`TIMESTAMP`, `VARBINARY` → `VARBYTE`) [RS-20…RS-27]; `IDENTITY(seed, step)` kept [RS-33]; defaults
mapped (`GETDATE()` kept, `NEWID()` flagged) [RS-34]; PK/UNIQUE/FK kept as informational
[RS-32]; `CHECK` dropped with a ledger row [RS-04]; indexes become sort-key candidates [RS-31];
computed columns and unmappable types become `-- TODO: MANUAL REVIEW REQUIRED` lines and the
status is `PARTIAL` (exit 1) [RS-35, RS-27]. Then write the uniqueness proof (`V-014`) for every
informational key — see `references/examples/01_sales_tables.redshift.sql`.

### Step 2: Views, procedures, ETL SQL — translate with the rules, then check
Translate by hand following `redshift.md`: keep what Redshift keeps (`GETDATE`, `DATEADD`,
`DATEDIFF`, `CHARINDEX`, `LEN`, `TOP`) [RS-10]; replace `ISNULL`/`IIF`/`STRING_AGG`/`+`/`N''`/
`[brackets]`/`NOLOCK` [RS-11…RS-18]; procedures become PL/pgSQL with `INOUT refcursor` or temp-table
results, implicit transactions, limited exception handling, `GET DIAGNOSTICS` [RS-40…RS-46]; MERGE is
split when it has more than one `WHEN MATCHED` or a `BY SOURCE` branch [RS-50, RS-51]; edge views
over rebuilt or external tables are late-binding and fully schema-qualified [RS-52]; recursive
CTEs carry a column list and `ROW_NUMBER` filters become `QUALIFY` [RS-53, RS-57].
```bash
python3 .kiro/skills/sql-conversion-redshift/scripts/redshift_tool.py check generated/redshift/v_customer_summary.sql --source source/v_CustomerSummary.sql
```
`check` must report **0 problems**: residual T-SQL, unsupported features, bare `TEXT`, late-binding
qualification, MERGE limits, security findings (`SEC-01…04`: injection, hidden characters,
credentials, dangerous statements) and constructs introduced versus the source (`SEC-09`, e.g. an
`UNLOAD` that was not in the T-SQL). Warnings (`RS-13` LISTAGG order, `RS-42` exception semantics,
`RS-51` duplicate-source MERGE, `RS-60` collation) must be answered in the ledger.

### Step 3: Security-bearing objects
Identity functions (`ORIGINAL_LOGIN`, `IS_MEMBER`, `SESSION_CONTEXT`) and authorization joins are
not translated inline: emit a presentation view plus **RLS and masking policy drafts** with a
`TODO: MANUAL REVIEW REQUIRED` line, status `PARTIAL`, stop code `SECURITY_MAPPING_REQUIRED` until the
login→user and group→role mapping is approved [RS-61] (`references/examples/05_secure_employee_view.*`).
Never write `COPY … CREDENTIALS`, `CREATE USER … PASSWORD` or `UNLOAD` to buckets that were not
part of the request [RS-62].

### Step 4: Rule ledger and package
```bash
python3 .kiro/skills/sql-conversion-redshift/scripts/redshift_tool.py ledger source/v_CustomerSummary.sql generated/redshift/v_customer_summary.sql
python3 .kiro/skills/sql-conversion-redshift/scripts/redshift_tool.py package source/v_CustomerSummary.sql generated/redshift/v_customer_summary.sql --out generated/redshift/pkg/v_customer_summary --classification generated/assessment/v_CustomerSummary.classification.json
```
The package holds `request.json`, `output.json` (universal output contract with status, stop codes,
ledger, warnings, manual review items, validation manifest), `rule-ledger.md`, both SQL files and
`manifest.json` with SHA-256 hashes and the audit run id. Add rows the inference missed with a
reason; every non-trivial change must be explainable.

### Step 5: Execution evidence (optional, test databases only)
```bash
python3 .kiro/skills/sql-conversion-redshift/scripts/redshift_tool.py run generated/redshift/v_customer_summary.sql --database dw_test --workgroup-name analytics-dev --evidence generated/redshift/pkg/v_customer_summary/run.json
python3 .kiro/skills/sql-conversion-redshift/scripts/redshift_tool.py package … --evidence generated/redshift/pkg/v_customer_summary/run.json   # → VALIDATED
```
`run` uses the Redshift Data API (`batch-execute-statement`, ≤ 200 KB per request, idempotent
client token) through the kit's AWS service layer (`migkit/services.py`). Guardrails: the database
name must contain `test`, `dev`, `sandbox` or `local` (exit 3 otherwise); the SQL is security-scanned
first; nothing is executed when the service is unavailable — `V-004` stays listed as unexecuted
[RS-70]. Provisioning a workgroup or cluster is never done by this skill.

## Guardrails and audit
- Inputs are scanned (`SEC-01…03`) and size-limited; refusals exit 3 and are audited without the secret.
- Generated SQL is scanned for dangerous or data-moving statements (`SEC-04`) and diffed against
  the source (`SEC-09`); `check` fails on critical findings.
- Every command writes correlated audit records under the run id (`redshift.convert_ddl`,
  `redshift.check`, `redshift.execute`, `redshift.result`, `redshift.package`, `security.refused`);
  SQL is logged by hash, never by content.
- Statuses only escalate (`GENERATED` → `PARTIAL` → `BLOCKED`); `VALIDATED` needs execution evidence.

## Verify the skill itself
`bash .kiro/skills/sql-conversion-redshift/scripts/run_skill_tests.sh` (Windows:
`.kiro\skills\sql-conversion-redshift\scripts\run_skill_tests.cmd`): 13 unit tests on fixtures and
the worked examples, the Data API path against the stub AWS CLI, and coverage of all `RS-nn` rows.
Set `REDSHIFT_DATABASE` (a test database) and `REDSHIFT_WORKGROUP` or `REDSHIFT_CLUSTER` to add a
live run; nothing is created in AWS.
