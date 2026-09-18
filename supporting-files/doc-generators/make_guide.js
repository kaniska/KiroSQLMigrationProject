const fs = require('fs');
const {
  Document, Packer, Paragraph, TextRun, HeadingLevel, AlignmentType, Table, TableRow, TableCell,
  WidthType, ShadingType, BorderStyle, LevelFormat, Footer, PageNumber, TabStopType, Tab,
} = require('docx');

const OUT = process.argv[2];
const FONT = 'Calibri';
const MONO = 'Consolas';
const ACCENT = '1F4E79';
const TABLE_W = 9026;            // A4 text width with 1" margins (DXA)

// ---------- helpers ----------
const t = (text, opts = {}) => new TextRun({ text, font: FONT, size: 22, ...opts });
const code = (text) => new TextRun({ text, font: MONO, size: 20, color: '1F1F1F' });

// inline markup: `code` and **bold**
function runs(str, base = {}) {
  const out = [];
  str.split(/(`[^`]+`|\*\*[^*]+\*\*)/).forEach((part) => {
    if (!part) return;
    if (part.startsWith('`')) out.push(new TextRun({ text: part.slice(1, -1), font: MONO, size: 20, ...base }));
    else if (part.startsWith('**')) out.push(t(part.slice(2, -2), { bold: true, ...base }));
    else out.push(t(part, base));
  });
  return out;
}
const p = (str, opts = {}) => new Paragraph({ children: runs(str), spacing: { after: 120, line: 276 }, ...opts });
const h1 = (text) => new Paragraph({ heading: HeadingLevel.HEADING_1, children: [new TextRun({ text, font: FONT })] });
const h2 = (text) => new Paragraph({ heading: HeadingLevel.HEADING_2, children: [new TextRun({ text, font: FONT })] });
const bullet = (str) => new Paragraph({ numbering: { reference: 'bullets', level: 0 }, children: runs(str), spacing: { after: 60 } });
let numRef = 0;
const steps = (items, cont) => {
  const ref = cont || `steps${numRef++}`;
  if (!cont) numberingConfigs.push({ reference: ref, levels: [{ level: 0, format: LevelFormat.DECIMAL, text: '%1.',
    alignment: AlignmentType.LEFT, style: { paragraph: { indent: { left: 540, hanging: 360 } } } }] });
  return items.map((s) => new Paragraph({ numbering: { reference: ref, level: 0 }, children: runs(s), spacing: { after: 80 } }));
};
const cmd = (line) => new Paragraph({
  children: [code(line)],
  shading: { type: ShadingType.CLEAR, color: 'auto', fill: 'F2F4F7' },
  spacing: { before: 40, after: 40 },
  indent: { left: 200 },
});
const codeblock = (lines, fill = 'F2F4F7') => lines.map((line, i) => new Paragraph({
  children: [code(line === '' ? ' ' : line)],
  shading: { type: ShadingType.CLEAR, color: 'auto', fill },
  spacing: { before: i === 0 ? 60 : 0, after: i === lines.length - 1 ? 100 : 0, line: 240 },
  indent: { left: 200 },
}));
const label = (str) => new Paragraph({ children: runs(str, { bold: true, size: 20, color: '2E5C8A' }), spacing: { before: 120, after: 40 } });
const note = (str) => new Paragraph({
  children: runs(str, { size: 20 }),
  shading: { type: ShadingType.CLEAR, color: 'auto', fill: 'FFF4E5' },
  border: { left: { style: BorderStyle.SINGLE, size: 18, color: 'E8A33D', space: 8 } },
  spacing: { before: 80, after: 160 }, indent: { left: 160 },
});

const border = { style: BorderStyle.SINGLE, size: 4, color: 'BFC7D5' };
const borders = { top: border, bottom: border, left: border, right: border };
function table(widths, header, rows) {
  const mk = (cells, head) => new TableRow({
    tableHeader: head,
    children: cells.map((c, i) => new TableCell({
      borders,
      width: { size: widths[i], type: WidthType.DXA },
      shading: head ? { type: ShadingType.CLEAR, color: 'auto', fill: 'DCE6F2' } : undefined,
      margins: { top: 60, bottom: 60, left: 100, right: 100 },
      children: [new Paragraph({ children: runs(c, head ? { bold: true, size: 20 } : { size: 20 }) })],
    })),
  });
  return new Table({
    width: { size: TABLE_W, type: WidthType.DXA },
    columnWidths: widths,
    rows: [mk(header, true), ...rows.map((r) => mk(r, false))],
  });
}
const gap = () => new Paragraph({ children: [], spacing: { after: 80 } });

const numberingConfigs = [
  { reference: 'bullets', levels: [{ level: 0, format: LevelFormat.BULLET, text: '•', alignment: AlignmentType.LEFT,
    style: { paragraph: { indent: { left: 540, hanging: 300 } } } }] },
];

// ---------- content ----------
const body = [
  new Paragraph({ children: [new TextRun({ text: 'SQL Server → Aurora PostgreSQL', font: FONT, size: 44, bold: true, color: ACCENT })], spacing: { after: 60 } }),
  new Paragraph({ children: [new TextRun({ text: 'Migration with Kiro — User Guide', font: FONT, size: 32, color: '404040' })], spacing: { after: 80 } }),
  new Paragraph({ children: [t('eight skills · targets: Aurora PostgreSQL · Amazon Redshift · Iceberg on S3 · two agents (conversion, reporting) · September 2026', { size: 20, color: '707070' })],
    border: { bottom: { style: BorderStyle.SINGLE, size: 8, color: ACCENT, space: 6 } }, spacing: { after: 240 } }),

  h1('1. What it does'),
  p('This kit lets Kiro move a SQL Server estate to its approved targets — PostgreSQL on Amazon Aurora for database code, Amazon Redshift for the warehouse, Apache Iceberg tables on S3 (Athena, Glue, Spark) for the data lake: it assesses and routes each object, converts code and table definitions, writes the reports that run on the converted data, migrates Informatica ETL exports, checks that source and target schemas match, and applies rename/cast requests safely — and **proves** every result with automatic tests or a run on a test target.'),
  bullet('**Rules** tell Kiro what a correct conversion looks like: `governance.md` (contracts, statuses, stop codes, which skill), `migration.md` (PostgreSQL), `redshift.md`, `iceberg.md`, `schema.md`, `security.md`.'),
  bullet('**Eight skills** tell Kiro how to do one unit of work and prove it: `migration-assessment` (what is it, where should it go), `sql-conversion` (T-SQL → PostgreSQL), `sql-conversion-redshift`, `sql-conversion-iceberg`, `sql-reporting` (report and dashboard SQL), `informatica-etl-conversion` (PowerCenter XML), `schema-conformance` (source vs target schema), `schema-change-propagation` (renames and casts).'),
  bullet('**Two agents** run the jobs with safe permissions: `sql-migration-agent` (the conversion assistant — asks the intake questions, picks the skill, converts, checks, packages) and `sql-reporting-agent` (the reporting SQL assistant for PostgreSQL, Redshift, Athena and Spark). Prompts: `.kiro/agents/prompts/examples.md`; catalog: `.kiro/agents/AGENTS.md`.'),
  note('Golden rule: the new code must behave exactly like the old code — even where the old code has a bug. Kiro keeps the behaviour and flags it for you to decide.'),

  h1('2. What you need'),
  table([2600, 3626, 2800], ['Item', 'Why', 'Check'], [
    ['Kiro IDE or Kiro CLI', 'Runs the skill and the agent', '`kiro-cli --version`'],
    ['PostgreSQL client (psql 16+)', 'Runs the tests', '`psql --version`'],
    ['AWS CLI with credentials', 'Creates the 15-minute database login token', '`aws sts get-caller-identity`'],
    ['A TEST database (PostgreSQL 17)', 'Tests rebuild tables — never use production', 'name contains `test`, `dev`, `sandbox` or `local`'],
    ['Python 3.9+', 'Tools, hooks and checks (Windows: tick “Add python.exe to PATH”)', '`python3 --version` · Windows: `python --version`'],
    ['Windows only: PowerShell 5.1+', 'Runs the `.cmd` / `.ps1` versions of every script (built into Windows)', '`powershell $PSVersionTable.PSVersion`'],
  ]),
  gap(),

  h1('3. One-time setup'),
  ...steps([
    'Open the project folder in Kiro (IDE: **File → Open Folder**; CLI: `cd` into it).',
    'Check the connection settings in `metadata/test_connection.env` (host, database, user, region). No passwords go here.',
    'Run all tests once — the last line must say **RESULT: PASS**:',
  ]),
  cmd('bash supporting-files/run_tests.sh'),
  p('On **Windows** run `supporting-files\\run_tests.cmd` instead, and use the agent `sql-migration-agent-windows`. Every `.sh` script has a `.cmd` launcher next to it that takes the same arguments.'),
  ...steps([
    'Using **Kiro Crew**? Open the Crew dashboard and grant this folder **trust**, so the project skills load.',
    'Optional: install `uv` (`brew install uv`) if you want the MCP servers described in section 11.',
  ], 'steps0'),

  h1('4. Convert a procedure'),
  p('Put the SQL Server file in `source/` (for example `source/usp_GetInvoices.sql`), then pick one way:'),
  table([2300, 6726], ['Where', 'What to do'], [
    ['Kiro IDE — chat', 'Type: `Convert source/usp_GetInvoices.sql to PostgreSQL` (or `/sql-conversion source/usp_GetInvoices.sql`).'],
    ['Kiro IDE — agent', 'Choose **sql-migration-agent** in the agent selector, then type: `Migrate everything pending`.'],
    ['Kiro CLI — interactive', '`kiro-cli chat --agent sql-migration-agent`, then type your request.'],
    ['Kiro CLI — one command', '`kiro-cli chat --no-interactive --agent sql-migration-agent "Convert source/usp_GetInvoices.sql"`'],
    ['Many files at once', '`bash supporting-files/kiro_migrate.sh` — converts every pending file, writes one log per file in `logs/`, then runs all tests.'],
  ]),
  gap(),
  p('For every object Kiro will:'),
  ...steps([
    'Read the source and the table definitions.',
    'Write `generated/<name>.sql` with a header explaining each decision.',
    'Add tests to `tests/test_cases.sql` and register the file in `tests/test_runner.sql`.',
    'Update `metadata/migration_log.json`.',
    'Run the tests until they pass, then report what changed and what needs your decision.',
  ]),

  h1('5. Examples of using the skill'),
  p('Type these in Kiro chat (IDE or `kiro-cli chat`). The skill loads automatically when you mention converting SQL Server / T-SQL to PostgreSQL; `/sql-conversion` forces it.'),
  table([4300, 4726], ['You type', 'What happens'], [
    ['`/sql-conversion source/usp_GetActiveCustomers.sql`', 'Converts the file, adds tests, updates the log, runs the tests.'],
    ['`Convert this T-SQL to PostgreSQL:` + paste the code', 'Converts a snippet shown in chat; ask it to save to `generated/` if you want to keep it.'],
    ['`Which corner cases apply to source/usp_X.sql? Do not convert yet.`', 'Lists the risky constructs and the rules that will apply.'],
    ['`Review generated/sales_reporting.sql for parity issues`', 'Checks the code against the rules and runs the tests; reports findings.'],
    ['`Add tests for get_order_history: NULL search text and paging`', 'Adds tagged tests to `tests/test_cases.sql` and runs them.'],
    ['`Convert source/schema/new_tables.sql and add it to generated/schema.sql`', 'Converts table definitions (types, identities, constraints).'],
    ['`Why was DATEDIFF(month) not converted with AGE()?`', 'Explains the rule (SQL Server counts month boundaries) with the reference.'],
  ]),
  gap(),
  h2('Mini example'),
  label('SQL Server source — source/usp_GetActiveCustomers.sql'),
  ...codeblock([
    'CREATE PROCEDURE dbo.usp_GetActiveCustomers @MinOrders INT = 1',
    'AS',
    "SELECT TOP 10 c.CustomerId, c.FirstName + ' ' + c.LastName AS Name, COUNT(*) AS Orders",
    'FROM dbo.Customers c WITH (NOLOCK)',
    'JOIN dbo.Orders o ON o.CustomerId = c.CustomerId',
    'GROUP BY c.CustomerId, c.FirstName, c.LastName',
    'HAVING COUNT(*) >= @MinOrders',
    'ORDER BY Orders DESC;',
  ], 'FDF1F1'),
  label('What the skill produces — generated/get_active_customers.sql'),
  ...codeblock([
    'CREATE OR REPLACE FUNCTION public.get_active_customers(p_min_orders INTEGER DEFAULT 1)',
    'RETURNS TABLE(customer_id INTEGER, name TEXT, orders INTEGER)',
    'LANGUAGE sql STABLE',
    'AS $$',
    "    SELECT c.customer_id, c.first_name || ' ' || c.last_name, COUNT(*)::INTEGER",
    '    FROM   public.customers c',
    '    JOIN   public.orders    o ON o.customer_id = c.customer_id',
    '    GROUP  BY c.customer_id, c.first_name, c.last_name',
    '    HAVING COUNT(*) >= p_min_orders',
    '    ORDER  BY 3 DESC',
    '    LIMIT  10;',
    '$$;',
  ], 'EEF6EE'),
  p('Why it looks like this: a procedure returning rows becomes a function returning a table; `dbo.` becomes `public.` and names become snake_case; `WITH (NOLOCK)` is removed; `+` becomes `||`; `COUNT(*)` is cast to INTEGER (SQL Server\'s type); `TOP 10` becomes `LIMIT 10`. Call it with `SELECT * FROM public.get_active_customers(2);`'),


  h1('6. Write a report (sql-reporting skill)'),
  p('Ask for the report in plain words. Kiro pins down the definition first (which orders count, which period, which time zone), writes the SQL as a tested PostgreSQL function, and checks that the numbers add up before handing it over.'),
  table([4300, 4726], ['You type', 'What you get'], [
    ['`Monthly revenue for 2025, empty months as 0`', 'a `report_revenue_by_month(from, to)` function; July shows 0, not a missing row'],
    ['`Revenue by category with share of total`', 'line-level aggregation, no double counting; shares add up to 100'],
    ['`MoM and YoY growth for 2025`', 'growth over a gap-filled series; growth from zero is empty, not an error'],
    ['`Top 3 products per category, ties kept`', '`DENSE_RANK` so a tied product is never dropped'],
    ['`Which customers make 80% of revenue?`', 'ranking with cumulative share'],
    ['`Cohort retention by first purchase month`', 'cohort matrix with the cohort size as denominator'],
    ['`Stock on hand at 30 June`', 'last snapshot per product — never a sum across days'],
    ['`Review this dashboard query: <paste>`', 'findings against the 24 query rules (double counting, time zones, rounding…)'],
  ]),
  note('Why it matters: a report that runs is not a report that is right. Each of the 24 rules in `.kiro/skills/sql-reporting/references/patterns.md` changed a real number — e.g. summing order totals over order lines turns 4 999 into 8 309.'),
  p('Test the skill: `bash .kiro/skills/sql-reporting/scripts/run_skill_tests.sh` (15 report patterns, 88 checks).'),
  p('Reports on **Redshift, Athena or Spark**: say the target ("… on Redshift"). The same rules apply; the dialect catalog (`references/dialects.md`, RD-01…18) gives the spelling per engine and `report_tool.py check --target redshift|athena|spark` verifies it. Worked examples: `references/examples/redshift`, `athena`, `spark`. Use the dedicated agent: `kiro-cli chat --agent sql-reporting-agent`.'),
  p('Full guide for analysts: `docs/Reporting_Analytics_SQL_User_Guide.docx`.'),

  h1('7. Migrate Informatica ETL (informatica-etl-conversion skill)'),
  p('Export the workflow from PowerCenter as XML, put it in `source/informatica/`, and ask:'),
  cmd('Convert source/informatica/wf_Load_Orders.xml for PostgreSQL'),
  p('Kiro then:'),
  ...steps([
    'Pulls every piece of SQL out of the XML with the tool (`infa_sql_tool.py extract`): Source Qualifier overrides, filters, joins, lookup overrides, pre/post SQL, update overrides, stored-procedure calls, SQL transformations — at mapping, session and reusable level.',
    'Converts each one, keeping Informatica syntax intact (`$$PARAMS`, `?ports?`, `:TU.ports`, `{ }` joins, the `ORDER BY … --` lookup rule).',
    'Checks the result (`check`): no leftover T-SQL, no trailing semicolons, right number of columns, parameters unchanged.',
    'Writes a new XML (`inject --map`): only the SQL and the database settings change — connection types, `dbo` owners, native datatypes, Bulk load, renamed tables and columns everywhere they appear.',
    'Runs the converted SQL with your parameter values on the test database and reports what still needs a human: stored-procedure transformations, temp tables, sorted ports, `DBCC` statements.',
  ]),
  table([3300, 5726], ['File', 'Meaning'], [
    ['`generated/informatica/<name>.sql/`', 'one reviewable file per SQL attribute + `manifest.json`'],
    ['`generated/informatica/<name>.postgres.xml`', 'the file you import into the target repository'],
    ['`generated/informatica/pg_map.json`', 'the table/column/datatype/connection map (copy the example)'],
  ]),
  note('Outside the XML you still: create PostgreSQL connection objects with the same `$DBConnection_*` names, re-validate the mappings in Designer, and run one session against the test database. Never edit the XML by hand — entities and byte-exactness are the tool’s job.'),
  p('Real PowerCenter exports are usually **Windows-1252 or ISO-8859-1**, with Windows line breaks and `NAME ="…"` spacing. The tool keeps all of that, so an unchanged file comes back byte for byte (checked on public exports from GitHub). If the export contains text aimed at an AI, hidden characters or passwords, they are listed in `manifest.json` under `security`. Kiro reports them to you and never follows them.'),
  p('Targets other than PostgreSQL: `check --target redshift` or `--target iceberg` applies the Redshift or Spark rules to every SQL fragment, and `inject --map params/redshift_map.json` (or `iceberg_map.json`) sets the connection types, owners and datatypes. For the Iceberg lake PowerCenter lands files on S3 and the Glue job from the Iceberg skill loads the table — PowerCenter does not write Iceberg tables directly.'),
  p('Test the skill: `bash .kiro/skills/informatica-etl-conversion/scripts/run_skill_tests.sh` (5 example mappings — one in real export format with a full SQL Server job — and 46 corner cases, including security, audit and the Redshift/Iceberg targets).'),

  h1('8. Choose the target: assess, Redshift, Iceberg, schema checks, schema changes'),
  p('When the target is not Aurora — or not decided yet — start by asking the agent to **assess**. It inventories every object, says who consumes it, where it should live (Materialize the Middle, Retain Views on the Edge), how complex it is, which targets are feasible and which skill converts it. Missing decisions come back as questions, never as guesses.'),
  table([3300, 5726], ['You type', 'What you get'], [
    ['`Assess source/ for a BI migration; target undecided`', 'per object: role, complexity L1–L4, review tier, target candidates with blockers, recommended skill; `generated/assessment/*.assessment.md`'],
    ['`Convert source/schema/*.sql to Redshift with metadata/design/redshift.json`', 'Redshift DDL with your DISTSTYLE/SORTKEY decisions (AUTO when you gave none), informational keys, a rule ledger, a package'],
    ['`Rewrite v_CustomerSummary as a Redshift late-binding view`', 'converted view, `check` with 0 problems, ledger (ISNULL → NVL, STRING_AGG → LISTAGG …), optional run on a test workgroup'],
    ['`Land dbo.FactSales as an Iceberg table partitioned by day(SaleDate)`', 'Athena and Spark DDL (`string` with source lengths in comments), partition transforms from your design file, S3 location from the design file'],
    ['`Generate the Glue MERGE job for customer_summary keyed on customer_key`', 'a Glue 5.x PySpark job rendered from a template: deduplicated source, idempotent MERGE, audit counts; compiled and security-scanned'],
    ['`Compare source/schema with generated/schema.sql`', '`compare.md`: every column EXACT / APPROVED_TRANSFORM / MISSING / CONFLICT / UNVERIFIED, keys, column order; dry-run fix proposals'],
    ['`Apply metadata/changes/q3.csv to generated/ as a dry run`', 'cast-before-rename plan, diff of the editable files only, migration and rollback scripts, residual scan, cast-safety findings for review'],
  ]),
  note('Design decisions are yours: distribution and sort keys, partition transforms, S3 locations, identity mappings for security views, dispositions for risky casts. The tools emit AUTO or placeholders and mark the result PARTIAL until you decide; nothing is applied to a live target and no AWS resource is ever created by the kit.'),
  p('Redshift and Athena runs (`run`) only work against databases whose name contains `test`, `dev`, `sandbox` or `local`, and only when you have configured them (`REDSHIFT_DATABASE` + `REDSHIFT_WORKGROUP`, `ATHENA_DATABASE`). Without them the skills still convert, check and package; the execution check is listed as not executed.'),
  p('Test the skills: `bash .kiro/skills/<skill>/scripts/run_skill_tests.sh` (Windows: `.cmd`) for `migration-assessment`, `sql-conversion-redshift`, `sql-conversion-iceberg`, `schema-conformance`, `schema-change-propagation` — no database needed.'),

  h1('9. Check the result'),
  cmd('bash supporting-files/run_tests.sh'),
  p('You will see a summary per test group, a list of failures (empty when all is well), and:'),
  table([3300, 5726], ['Line', 'Meaning'], [
    ['`Project suites : PASS`', 'Your converted code behaves as expected.'],
    ['`Skill self-tests: PASS`', 'All eight skills\' examples and corner cases still work (five of them need no database).'],
    ['`Agent hooks    : PASS`', 'The agent guardrails block what they should and the audit hooks work.'],
    ['`COVERAGE: PASS`', 'Every rule in the rulebook has at least one test.'],
    ['`Run id         : 8717…`', 'The id of this run. Find everything it did with `audit.py tail --run 8717…` (section 11).'],
    ['`RESULT: PASS`', 'Everything above passed. Anything else: read the failures table.'],
  ]),
  gap(),
  p('A failing test name ends with a tag such as `[P4]` or `[CC-43]`. Look it up in `.kiro/steering/migration.md` (P/H rules) or `.kiro/skills/sql-conversion/references/corner-cases.md` (CC cases) to see the rule it checks.'),

  h1('10. Review the flags'),
  p('Some differences need a human decision. Kiro never hides them: the code says `-- TODO: MANUAL REVIEW REQUIRED — <reason>` and `metadata/migration_log.json` says `"manual_review": true`.'),
  table([3600, 5426], ['Flag', 'Your decision'], [
    ['Source bug preserved (e.g. expired coupon accepted)', 'Keep for parity during cut-over, or fix in both systems.'],
    ['One procedure returned two result sets', 'Update callers to call the two new functions.'],
    ['Report excludes late orders on the last day', 'Confirm the old report really worked this way.'],
    ['New code is all-or-nothing where the old one was not', 'Usually safer — confirm nobody relied on partial saves.'],
  ]),
  gap(),

  h1('11. Stay safe: guardrails, audit trail, AWS'),
  p('Source files and XML exports are **untrusted**. They could contain text written to trick an AI (“ignore your instructions and…”). The kit does not rely on Kiro noticing: fixed checks run outside the model.'),
  table([3000, 6026], ['Protection', 'What it does'], [
    ['Input scan', 'Finds instructions aimed at an AI, invisible characters, passwords and keys, and dangerous SQL in any file: `security.py scan <file>`.'],
    ['Safe XML reading', 'Informatica files with entity tricks or remote DTDs are refused (exit code 3).'],
    ['Conversion check', 'A conversion may not add things the source did not have, such as running programs, reading server files or remote connections. Refused with exit code 3.'],
    ['Agent guard hook', 'Blocks reading credentials, sending data out, deleting files, changing `.kiro/` or the logs, changing AWS resources, and non-test databases. The agent sees `BLOCKED by guardrail GRD-nn`.'],
    ['Test preflight', 'Test files that run shell commands or contain secrets are refused before connecting (exit code 4). Superuser logins are refused.'],
  ]),
  gap(),
  label('Audit trail and troubleshooting'),
  p('Every run gets one **run id**. The Kiro session, every tool, every test session in PostgreSQL (`application_name mig:<file>:<first 8 characters>`) and every lineage record carry it. Records are JSON with UTC timestamps to the millisecond. They are chained with SHA-256, so an edited or deleted line is detected.'),
  cmd('python3 .kiro/skills/sql-conversion/scripts/migkit/audit.py tail --run 871771c8'),
  cmd('python3 .kiro/skills/sql-conversion/scripts/migkit/audit.py verify'),
  label('AWS services — optional, with a local fallback'),
  p('Without any setup everything stays on your machine under `logs/`. To use AWS, create the resources (commands and a least-privilege IAM policy are in `.kiro/skills/sql-conversion/references/aws-services.md`). Then copy `.kiro/settings/migration-services.example.json` to `migration-services.json` and fill in the names. If a service cannot be reached, the kit falls back to the local store and records why.'),
  table([2400, 3300, 3326], ['Need', 'AWS service', 'Local fallback'], [
    ['Audit trail', 'Amazon CloudWatch Logs', '`logs/audit/*.jsonl`'],
    ['Lineage', 'Amazon DataZone (OpenLineage)', '`logs/state/lineage.jsonl`'],
    ['Prompt-attack check', 'Amazon Bedrock Guardrails', 'built-in scanner (always on)'],
    ['Evidence archive', 'Amazon S3 with Object Lock', '`logs/archive/`'],
    ['Database password', 'AWS Secrets Manager', 'IAM token or `PGPASSWORD`'],
  ]),
  gap(),
  cmd('python3 .kiro/skills/sql-conversion/scripts/migkit/services.py status'),
  note('Kiro never creates AWS resources for you, and never use AWS root access keys for this work. Use an IAM Identity Center user or an IAM role.'),

  h1('12. Kiro CLI commands'),
  p('Commands checked against Kiro CLI 2.21. Terminal commands start with `kiro-cli`; chat commands start with `/` and are typed inside `kiro-cli chat`.'),
  h2('Skills'),
  table([4300, 4726], ['Task', 'Command'], [
    ['See which skills and steering files are loaded', 'in chat: `/context show` (lists `.kiro/skills/*/SKILL.md` and `.kiro/steering/*.md`)'],
    ['Browse skills as slash commands', 'in chat: type `/` → `/migration-assessment`, `/sql-conversion`, `/sql-conversion-redshift`, `/sql-conversion-iceberg`, `/sql-reporting`, `/informatica-etl-conversion`, `/schema-conformance`, `/schema-change-propagation`'],
    ['Use the skill explicitly', 'in chat: `/sql-conversion source/usp_X.sql`'],
    ['Use the skill from a script', '`kiro-cli chat --no-interactive --trust-tools=fs_read,fs_write,execute_bash "Use the sql-conversion skill to convert source/usp_X.sql and run the tests"`'],
    ['Test all eight skills, hooks, agents and the MCP placeholder', '`bash supporting-files/run_tests.sh --skill`'],
    ['Test the skill in any project', '`bash .kiro/skills/sql-conversion/scripts/run_skill_tests.sh`'],
    ['See skills in the IDE', 'Kiro panel → **Agent Steering & Skills**'],
  ]),
  gap(),
  h2('Agents'),
  table([4300, 4726], ['Task', 'Command'], [
    ['List agents', '`kiro-cli agent list` (run inside the project; shows `sql-migration-agent` and `sql-reporting-agent` as `Workspace`, plus their `-windows` twins)'],
    ['Check the agent files', '`bash supporting-files/verify_agents.sh` — structural tests + `kiro-cli agent validate` for all four files (`--smoke` adds one read-only prompt per agent); or `kiro-cli agent validate --path .kiro/agents/<agent>.json` (no output = valid)'],
    ['Start the conversion assistant', '`kiro-cli chat --agent sql-migration-agent` (Windows: `sql-migration-agent-windows`)'],
    ['Start the reporting assistant', '`kiro-cli chat --agent sql-reporting-agent` (Windows: `sql-reporting-agent-windows`)'],
    ['Run the agent without chat', '`kiro-cli chat --no-interactive --agent sql-migration-agent "Migrate everything pending"`'],
    ['List / switch agents inside chat', '`/agent`  ·  `/agent swap sql-migration-agent`'],
    ['Make it the default agent', '`kiro-cli agent set-default sql-migration-agent`'],
    ['Batch-migrate with the agent', '`bash supporting-files/kiro_migrate.sh`'],
  ]),
  gap(),
  h2('MCP servers'),
  table([4300, 4726], ['Task', 'Command'], [
    ['List servers (default agent and workspace agents)', '`kiro-cli mcp list`   (or `kiro-cli mcp list workspace`)'],
    ['Show one server\'s settings', '`kiro-cli mcp status --name awslabs.postgres-mcp-server`'],
    ['Turn on the AWS Knowledge server (workspace)', '`kiro-cli mcp add --scope workspace --name aws-knowledge --url https://knowledge-mcp.global.api.aws --force`'],
    ['Add / turn on the PostgreSQL server (workspace)', '`kiro-cli mcp add --scope workspace --name awslabs.postgres-mcp-server --command uvx --args \'["awslabs.postgres-mcp-server@latest","--privilege_check","enforce"]\' --env AWS_PROFILE=default --env AWS_REGION=us-east-1 --force`'],
    ['Turn a server off', 'add the same command with `--disabled`, or set `"disabled": true` in `.kiro/settings/mcp.json`'],
    ['Remove a server', '`kiro-cli mcp remove --scope workspace --name <server>`'],
    ['Import servers from another file', '`kiro-cli mcp import --file other-mcp.json workspace`'],
    ['See live servers and their tools in chat', '`/mcp`  ·  `/tools`  ·  `/tools trust <tool>`'],
    ['Use a server', 'in chat: `Connect to database my_test_db on Aurora PostgreSQL cluster my-cluster in us-east-1 using pgwire_iam, then show the columns of public.orders`'],
  ]),
  note('Agent servers: edit `.kiro/agents/sql-migration-agent.json` and set `"disabled": false` on the server you want. Avoid `kiro-cli mcp add --agent …` for this agent — it rewrites the file, copying the prompt text in and dropping the permissions block. Most servers need `uv` (`brew install uv`); AWS Knowledge needs nothing.'),
  table([3700, 5326], ['Server', 'Use it to'], [
    ['awslabs.postgres-mcp-server', 'Look up exact column names and types on the target (read-only).'],
    ['aws-knowledge (remote)', 'Ask AWS documentation questions — no install, no credentials.'],
    ['awslabs.aws-documentation-mcp-server', 'Search AWS documentation locally.'],
    ['awslabs.mssql-mcp-server', 'Read procedure code from an RDS for SQL Server source.'],
    ['awslabs.aws-api-mcp-server', 'Read AWS settings, e.g. the Aurora engine version (read-only).'],
  ]),
  note('Security: keep servers read-only; never put passwords in mcp.json; do not install the package "awslabs.aws-dms-mcp-server" — it is not from AWS.'),
  p('**The kit as an MCP server (placeholder):** `supporting-files/mcp/kit_mcp_server.py` serves the read-only tools (assess, check, compare, toolbox, audit) to any MCP client; it is registered as `sqlmigration-kit` in `.kiro/settings/mcp.json` and disabled until you switch it on. See `supporting-files/mcp/README.md` for what it does not do yet.'),

  h1('13. Use the kit in another project'),
  ...steps([
    'Copy `.kiro/steering/migration.md` and the folder `.kiro/skills/sql-conversion/` (and `.kiro/agents/` for the agent).',
    'Write `.kiro/steering/project.md` for the new project: target version, folders, test command.',
    'Prove the skill on your test database:',
  ]),
  cmd('PGHOST=<host> PGDATABASE=<test_db> PGUSER=<user> PG_IAM_AUTH=1 AWS_REGION=<region> \\'),
  cmd('  bash .kiro/skills/sql-conversion/scripts/run_skill_tests.sh'),
  ...steps(['Start converting (sections 4, 6, 7). Copy `tests/test_runner.sql` as the template for your own test list.'], 'steps2'),

  h1('14. Troubleshooting'),
  table([3700, 5326], ['You see', 'Do this'], [
    ['REFUSING TO RUN … not a test database', 'Connect to a database whose name contains test / dev / sandbox / local.'],
    ['could not generate an IAM auth token', 'Run `aws sts get-caller-identity`; your AWS user needs `rds-db:connect`.'],
    ['PostgreSQL 17+ required', 'Point the tests at a PostgreSQL 17 database.'],
    ['`/sql-conversion` not offered', 'Run `/context show` — the skill must be listed; in Crew, grant folder trust.'],
    ['Agent not listed', 'Run `kiro-cli agent list` inside the project folder.'],
    ['Skills, agent or scripts not found; “found kiro/ but no .kiro/”', 'The folder must be named exactly `.kiro` — rename it back (`mv kiro .kiro`; Windows: `Rename-Item kiro .kiro`). To see it: Finder Cmd + Shift + .  ·  Linux Ctrl + H'],
    ['An MCP server will not start', '`kiro-cli mcp status --name <server>`; install `uv`; fill in `<…>` placeholders.'],
    ['BLOCKED by guardrail GRD-nn', 'The agent tried something unsafe. Read the reason; if you really want it, do it yourself.'],
    ['REFUSED (security) · exit code 3 or 4', 'The file or the conversion contains something dangerous; the message names the rule and the line.'],
    ['connected role is a superuser', 'Use the least-privilege test user from `metadata/create_agent_user.sql`.'],
    ['What happened in run X?', '`audit.py tail --run <first 8 characters>`'],
  ]),
  gap(),

  h1('15. Open items (to do)'),
  p('These items are known and documented. None of them stops the tests from passing today. Details and commands: `README.md` section 15.'),
  table([2600, 6426], ['Area', 'To do'], [
    ['AWS access', 'Stop using root access keys. Create an IAM Identity Center user or IAM role with the least-privilege policy in `references/aws-services.md`.'],
    ['AWS services', 'Create the KMS key, CloudWatch Logs group, Bedrock guardrail, S3 Object Lock bucket and DataZone domain (Secrets Manager and CloudTrail only if needed). Then fill in `.kiro/settings/migration-services.json` and run `services.py sync`.'],
    ['Aurora cluster', 'Attach a custom parameter group (pgaudit, `application_name` in the log prefix), export PostgreSQL logs, reboot the writer, `CREATE EXTENSION pgaudit`.'],
    ['Business decisions', 'Six flagged objects: two end-of-month/end-date report quirks, the expired-coupon bug, two procedures split into two functions, and the atomic `create_order`. Keep or fix each one in both systems.'],
    ['After the data load', 'Resync identity sequences with `setval`.'],
    ['Informatica', 'Create PostgreSQL connection objects with the same names, re-validate mappings and sessions, run one test session. Verify for your PowerCenter version: Stored Procedure transformations over ODBC, the PostgreSQL `DATABASETYPE` value, which run-id variables expand in Pre/Post SQL. Enable high precision for decimals above 28 digits.'],
    ['Redshift and Iceberg', 'Point `REDSHIFT_DATABASE`/`REDSHIFT_WORKGROUP` and `ATHENA_DATABASE` at test resources for live evidence runs (the kit never creates them). Fill `metadata/design/redshift.json` and `metadata/design/iceberg.json` with your distribution, sort and partition decisions. Approve identity mappings for security views before attaching RLS policies.'],
    ['Kit', 'Enable the MCP servers when wanted. Move hooks to `.kiro/hooks/` when upgrading to Kiro CLI 3.0. Upgrade Python (Expat 2.7.2+).'],
    ['Roadmap', '**Next:** data validation at a snapshot (row counts, key sets, checksums) on all targets; Redshift Spectrum / managed Iceberg as a serving path. **AI-DLC integration (placeholder):** map the kit\'s gates and packages onto the AI-Driven Development Lifecycle (Inception = assessment, Construction = conversion units of work with the rule ledger, Operations = evidence runs) as steering plus a package adapter. **Later:** Oracle targets, Informatica ETL to Redshift/Oracle.'],
  ]),
  gap(),

  h1('16. Quick reference'),
  table([4600, 4426], ['Task', 'Command'], [
    ['Run everything', '`bash supporting-files/run_tests.sh`  ·  Windows: `supporting-files\\run_tests.cmd`'],
    ['Only your conversions / only the skill', '`bash supporting-files/run_tests.sh --project`  ·  `--skill`'],
    ['Local PostgreSQL instead of Aurora', '`TEST_TARGET=local bash supporting-files/run_tests.sh`'],
    ['Start the agent', '`kiro-cli chat --agent sql-migration-agent`  ·  Windows: `--agent sql-migration-agent-windows`'],
    ['Zip the project (includes the .kiro folder)', '`bash supporting-files/package.sh`  ·  Windows: `supporting-files\\package.cmd`'],
    ['See the hidden .kiro folder', 'macOS Finder: Cmd + Shift + .  ·  Linux: Ctrl + H  ·  Windows Explorer: visible'],
    ['List agents / MCP servers', '`kiro-cli agent list`  ·  `kiro-cli mcp list`'],
    ['List loaded skills (in chat)', '`/context show`'],
    ['Convert one file (in chat)', '`/sql-conversion source/usp_X.sql`'],
    ['Write a report (in chat)', '`/sql-reporting monthly revenue by category for 2025`'],
    ['Convert Informatica XML (in chat)', '`/informatica-etl-conversion source/informatica/wf_x.xml`'],
    ['Assess and route objects (in chat)', '`/migration-assessment assess source/ for a BI migration`'],
    ['Convert to Redshift / Iceberg (in chat)', '`/sql-conversion-redshift source/schema/x.sql`  ·  `/sql-conversion-iceberg source/schema/x.sql`'],
    ['Compare schemas / apply a change template (in chat)', '`/schema-conformance compare source/schema with generated/schema.sql`  ·  `/schema-change-propagation metadata/changes/x.csv`'],
    ['Convert all pending files', '`bash supporting-files/kiro_migrate.sh`'],
    ['Scan a file before converting', '`python3 .kiro/skills/sql-conversion/scripts/migkit/security.py scan <file>`'],
    ['Where do logs go (AWS or local)?', '`python3 .kiro/skills/sql-conversion/scripts/migkit/services.py status`'],
    ['Everything one run did', '`python3 .kiro/skills/sql-conversion/scripts/migkit/audit.py tail --run <run8>`'],
  ]),
  gap(),
  p('More detail: `README.md` (full guide), `docs/Technical_Architecture.docx` (how it is built), `docs/Reporting_Analytics_SQL_User_Guide.docx` (reports), `docs/Executive_Overview.pptx` (overview deck), `.kiro/skills/sql-conversion/SKILL.md` (the procedure), `.kiro/skills/sql-conversion/references/mcp-tools.md` (MCP servers), `metadata/mcp_config.md` (database access).', { spacing: { before: 120 } }),
];

const doc = new Document({
  creator: 'SQLMigrationProject',
  title: 'SQL Server to Aurora PostgreSQL — User Guide',
  styles: {
    default: { document: { run: { font: FONT, size: 22 } } },
    paragraphStyles: [
      { id: 'Heading1', name: 'Heading 1', basedOn: 'Normal', next: 'Normal', quickFormat: true,
        run: { size: 28, bold: true, font: FONT, color: ACCENT },
        paragraph: { spacing: { before: 280, after: 120 }, outlineLevel: 0, keepNext: true } },
      { id: 'Heading2', name: 'Heading 2', basedOn: 'Normal', next: 'Normal', quickFormat: true,
        run: { size: 24, bold: true, font: FONT, color: '2E5C8A' },
        paragraph: { spacing: { before: 200, after: 100 }, outlineLevel: 1, keepNext: true } },
    ],
  },
  numbering: { config: numberingConfigs },
  sections: [{
    properties: { page: { margin: { top: 1440, right: 1440, bottom: 1440, left: 1440 } } },
    footers: { default: new Footer({ children: [new Paragraph({
      tabStops: [{ type: TabStopType.RIGHT, position: TABLE_W }],
      children: [t('SQL Server → Aurora PostgreSQL · User Guide', { size: 16, color: '808080' }),
                 new TextRun({ children: [new Tab(), 'Page '], font: FONT, size: 16, color: '808080' }),
                 new TextRun({ children: [PageNumber.CURRENT], font: FONT, size: 16, color: '808080' })] })] }) },
    children: body,
  }],
});

Packer.toBuffer(doc).then((buf) => { fs.writeFileSync(OUT, buf); console.log('wrote', OUT, buf.length, 'bytes'); });
