// One-page quick reference (A4 landscape, three columns). Rebuild:
//   NODE_PATH=$(npm root -g) node supporting-files/doc-generators/make_quickref.js docs/SQLMigrationProject_Quick_Reference.docx
const fs = require('fs');
const { Document, Packer, Paragraph, TextRun, Table, TableRow, TableCell, WidthType, ShadingType, BorderStyle,
        TableLayoutType, PageOrientation, VerticalAlign } = require('docx');

const OUT = process.argv[2] || 'SQLMigrationProject_Quick_Reference.docx';
const FONT = 'Calibri', MONO = 'Consolas';
const INK = '0B2E3A', TEAL = '1F7A8C', LINE = 'C9D5D8', HEAD = 'DCEBEE';
const PAGE_W = 16838, PAGE_H = 11906, MARGIN = 520;        // A4 landscape, ~0.9 cm margins
const CONTENT_W = PAGE_W - 2 * MARGIN;
const GAP = 140;
const COL_W = Math.floor((CONTENT_W - 2 * GAP) / 3);
const SZ = 14;                                             // 7 pt body

function runs(str, base = {}) {
  const out = [];
  String(str).split(/(`[^`]+`|\*\*[^*]+\*\*)/).forEach((part) => {
    if (!part) return;
    if (part.startsWith('`')) out.push(new TextRun({ text: part.slice(1, -1), font: MONO, size: SZ - 1, color: '1F1F1F', ...base }));
    else if (part.startsWith('**')) out.push(new TextRun({ text: part.slice(2, -2), font: FONT, size: SZ, bold: true, ...base }));
    else out.push(new TextRun({ text: part, font: FONT, size: SZ, ...base }));
  });
  return out;
}
const none = { style: BorderStyle.NONE, size: 0, color: 'FFFFFF' };
const noBorders = { top: none, bottom: none, left: none, right: none };
const tableNoBorders = { ...noBorders, insideHorizontal: none, insideVertical: none };
const thin = { style: BorderStyle.SINGLE, size: 2, color: LINE };
const thinBorders = { top: thin, bottom: thin, left: thin, right: thin };
const sp = (after = 20) => ({ before: 0, after, line: 224 });
const h = (text) => new Paragraph({ spacing: { before: 60, after: 26 }, keepNext: true,
  border: { bottom: { style: BorderStyle.SINGLE, size: 6, color: TEAL, space: 1 } },
  children: [new TextRun({ text, font: FONT, size: 18, bold: true, color: INK })] });
const p = (str, o = {}) => new Paragraph({ spacing: sp(o.after ?? 22), children: runs(str, o.run || {}) });
const b = (str) => new Paragraph({ spacing: sp(8), indent: { left: 150, hanging: 110 }, children: [new TextRun({ text: '•  ', font: FONT, size: SZ, color: TEAL, bold: true }), ...runs(str)] });
function grid(widthsPct, header, rows, width = COL_W) {
  const widths = widthsPct.map((x) => Math.floor(width * x));
  const mk = (cells, isHead) => new TableRow({ children: cells.map((c, i) => new TableCell({
    borders: thinBorders, width: { size: widths[i], type: WidthType.DXA },
    shading: isHead ? { type: ShadingType.CLEAR, color: 'auto', fill: HEAD } : undefined,
    margins: { top: 8, bottom: 8, left: 46, right: 36 }, verticalAlign: VerticalAlign.CENTER,
    children: [new Paragraph({ spacing: { before: 0, after: 0, line: 212 }, children: runs(c, isHead ? { bold: true, color: INK } : {}) })],
  })) });
  return new Table({ layout: TableLayoutType.FIXED, width: { size: widths.reduce((a, c) => a + c, 0), type: WidthType.DXA }, columnWidths: widths,
    rows: [...(header ? [mk(header, true)] : []), ...rows.map((r) => mk(r, false))] });
}
const gap = (after = 26) => new Paragraph({ spacing: { before: 0, after, line: 110 }, children: [] });

// ---------------- column 1: what it is ----------------
const col1 = [
  h('Skills (eight) — ask the agent or /skill-name'),
  grid([0.31, 0.44, 0.25], ['Skill', 'Does', 'Proven by'], [
    ['`migration-assessment`', 'Classify and route: inventory, role (M2RVE), complexity L1–L4, tier, target candidates + blockers, which skill', '12 rules MA'],
    ['`sql-conversion`', 'T-SQL procedures, functions, triggers, DDL → Aurora PostgreSQL', '17 examples · 87 CC'],
    ['`sql-conversion-redshift`', 'Tables, BI edge views, set-based loads → Amazon Redshift (design decisions, refcursor procs, MERGE limits, RLS drafts)', '5 pairs · 52 RS'],
    ['`sql-conversion-iceberg`', 'Tables, loads, Athena views, Glue Spark jobs → Iceberg on S3', '4 examples · 51 IB'],
    ['`sql-reporting`', 'Report and analytics requests → tested PostgreSQL functions', '15 patterns · 24 RQ'],
    ['`informatica-etl-conversion`', 'PowerCenter XML with SQL Server SQL → PostgreSQL', '5 mappings · 44 IC'],
    ['`schema-conformance`', 'Snapshots (DDL, live PostgreSQL, Glue) → per-column EXACT / APPROVED / MISSING / CONFLICT / UNVERIFIED, dry-run fixes, reference check', '22 rules SC'],
    ['`schema-change-propagation`', 'Rename/cast templates: cast before rename, protected layers, token-aware dry-run patches, rollback', '20 rules CP'],
  ]),
  h('Steering (always in context)'),
  grid([0.28, 0.72], null, [
    ['`governance.md`', 'Contracts, statuses GENERATED | PARTIAL | BLOCKED | VALIDATED, stop codes, gates, skill routing, intake questions [G]'],
    ['`migration.md`', 'PostgreSQL rules: type/syntax maps, hard [H], parity [P], checklist'],
    ['`redshift.md` · `iceberg.md`', 'Redshift [R] and Iceberg / Athena / Glue / Spark [I] rules and type maps'],
    ['`schema.md`', 'Schema conformance [S-1–9] and change propagation [S-10–13]'],
    ['`informatica-etl.md` · `security.md`', 'Informatica invariants [IE] · untrusted content, no secrets, AWS read-only, run id [S]'],
    ['`project.md`', 'This project: Aurora cluster, test DB, paths, commands, targets'],
  ]),
  h('Agent and hooks'),
  p('`sql-migration-agent` · `sql-migration-agent-windows`: router — asks consumer, target, contract, metadata, security, test target; then picks the skill. Prompts: `.kiro/agents/prompts/examples.md`.'),
  grid([0.28, 0.72], null, [
    ['agentSpawn', 'session run id · security notice · migration status'],
    ['preToolUse', '**guard** GRD-01..12: credentials, exfiltration, destructive commands, `.kiro`/log tampering, AWS changes, non-test DBs (also Redshift/Athena/Glue tools), installs, trust-all, applying change patches'],
    ['post · stop', 'redacted tool audit · session record · background sync'],
  ]),
];

// ---------------- column 2: commands ----------------
const col2 = [
  h('Skill tools (python3 · Windows: python)'),
  grid([0.36, 0.64], ['Tool', 'Commands'], [
    ['`assess_tool.py`', '`questions` · `assess <file|dir> --consumer --target --out` · `inventory` · `validate`'],
    ['`redshift_tool.py`', '`convert-ddl --design` · `check --source` · `ledger` · `run --database <test> --workgroup-name` · `package`'],
    ['`iceberg_tool.py`', '`ddl --design --out-dir` · `check --dialect athena|spark` · `job spec.json --out` · `ledger` · `run --database <test>` · `package`'],
    ['`schema_tool.py`', '`snapshot --dialect|--live|--glue` · `compare --profile aurora|redshift|iceberg` · `conform` · `refs` · `package`'],
    ['`change_tool.py`', '`ingest` · `validate` · `plan --snapshot --layers --policy --profile --flow` · `patch` · `scan` · `package`'],
    ['`infa_sql_tool.py`', '`extract` · `check` · `inject --map` · `render`'],
    ['`migkit/security.py` · `audit.py` · `services.py`', '`scan` · `tail --run <run8>` · `verify` · `status` · `sync`'],
  ]),
  h('Most used'),
  grid([0.52, 0.48], ['Linux / macOS', 'Windows'], [
    ['`bash supporting-files/run_tests.sh`', '`supporting-files\\run_tests.cmd`'],
    ['`bash .kiro/skills/<skill>/scripts/run_skill_tests.sh`', '`.kiro\\skills\\<skill>\\scripts\\run_skill_tests.cmd`'],
    ['`kiro-cli chat --agent sql-migration-agent`', '`… --agent sql-migration-agent-windows`'],
    ['`python3 supporting-files/make_skill_runners.py`', 'regenerates `.ps1`/`.cmd` twins (`--check`)'],
    ['`bash supporting-files/package.sh`', '`supporting-files\\package.cmd`'],
  ]),
  h('In Kiro chat'),
  grid([0.50, 0.50], null, [
    ['`Assess source/ for a BI migration; target undecided`', 'candidates + blockers, then you choose'],
    ['`/sql-conversion source/usp_X.sql`', 'Aurora conversion with tests'],
    ['`Convert source/schema/*.sql to Redshift with metadata/design/redshift.json`', 'Redshift DDL + ledger + package'],
    ['`Land dbo.FactSales as an Iceberg table partitioned by day(SaleDate)`', 'Athena + Spark DDL, Glue job'],
    ['`Compare source/schema with generated/schema.sql`', '`compare.md` with decisions'],
    ['`Apply metadata/changes/q3.csv to generated/ as a dry run`', 'plan, diff, migration + rollback'],
    ['`/sql-reporting monthly revenue for 2025`', 'tested report function'],
  ]),
  h('Statuses and stop codes'),
  p('`GENERATED` → `PARTIAL` (TODO: MANUAL REVIEW REQUIRED) → `BLOCKED` (decision missing) · `VALIDATED` = evidence on a test target. Stop codes are questions: `TARGET_DECISION_REQUIRED`, `METADATA_NOT_FOUND`, `SECURITY_MAPPING_REQUIRED`, `UNSAFE_CAST_REVIEW_REQUIRED`, `RENAME_COLLISION`, `TARGET_SCHEMA_DECISION_REQUIRED`, `PRODUCTION_WRITE_DENIED` …'),
  h('Exit codes'),
  grid([0.12, 0.88], null, [['1', 'check or test failed / gaps'], ['2', 'hook blocked the tool call, or usage/environment problem'], ['3', 'tool refused (security, non-test DB, production write)'], ['4', 'test preflight refused']]),
];

// ---------------- column 3: services, tests, docs ----------------
const col3 = [
  h('Targets and AWS (read-only, test resources only)'),
  grid([0.30, 0.70], null, [
    ['Aurora PostgreSQL 17', 'primary target; tests on `sql_migration_test` (IAM token per run)'],
    ['Amazon Redshift', '`redshift_tool.py run` via the Data API (`batch-execute-statement`) — DB name must contain test/dev/sandbox; set `REDSHIFT_DATABASE` + `REDSHIFT_WORKGROUP`'],
    ['Iceberg on S3', 'Athena `start-query-execution`, Glue Data Catalog `get-tables` — `ATHENA_DATABASE`; Glue jobs are generated, never deployed'],
    ['Evidence services', 'CloudWatch Logs · DataZone · Bedrock Guardrails · S3 Object Lock · Secrets Manager — local fallback in `logs/`'],
  ]),
  p('The kit never creates AWS resources. Nothing is applied to a live target: DDL, patches and jobs are packaged for the normal release path.', { after: 8 }),
  h('Packages (every skill)'),
  b('`request.json` · `output.json` (status, stop codes, ledger, warnings, manual review, validation manifest V-001…V-040) · `rule-ledger.md` · files · `manifest.json` with SHA-256 + run id'),
  h('Audit and lineage'),
  b('One `MIGRATION_RUN_ID` per run: Kiro session → tools → PostgreSQL `application_name` → Redshift/Athena statements → lineage; hash-chained JSONL, redacted'),
  h('Tests — 674 checks, all passing'),
  grid([0.66, 0.34], null, [
    ['Project suites (Aurora)', '153'],
    ['sql-conversion (SQL) · migkit + governance (unit)', '257 · 41'],
    ['sql-reporting (SQL) · Informatica (unit + SQL)', '88 · 27 + 38'],
    ['assessment · Redshift · Iceberg · schema · change (unit)', '12 · 13 · 10 · 8 · 9'],
    ['Agent hooks (incl. Windows parity)', '18'],
  ]),
  p('Coverage gate: every H/P/CC, RQ/RP, IC, SEC/LOG/SVC/GOV, MA/RS/IB/SC/CP, GRD/HOOK rule has a tagged test. Redshift/Athena/Glue paths run against a stub AWS CLI; live when test resources are configured.', { after: 8 }),
  h('Documents (docs/)'),
  b('`SQL_Migration_User_Guide.docx` · `Reporting_Analytics_SQL_User_Guide.docx` · `Technical_Architecture.docx` · `Executive_Overview.pptx` · `README.md` · this page'),
  h('Roadmap and open items (README §15)'),
  b('**Now:** point Redshift/Athena env vars at test resources · fill `metadata/design/*.json` · approve identity mappings · replace root AWS keys · decide 6 flagged objects'),
  b('**Next:** data validation at a snapshot on all targets · Spectrum / managed Iceberg serving · **AI-DLC integration (placeholder: steering + package adapter)** · later: Oracle, Informatica → Redshift/Oracle'),
];

const colCell = (children) => new TableCell({ borders: noBorders, width: { size: COL_W, type: WidthType.DXA }, margins: { top: 0, bottom: 0, left: 0, right: 0 }, children });
const gapCell = () => new TableCell({ borders: noBorders, width: { size: GAP, type: WidthType.DXA }, children: [new Paragraph({ children: [] })] });
const titleBar = new Table({ borders: tableNoBorders, layout: TableLayoutType.FIXED, width: { size: CONTENT_W, type: WidthType.DXA }, columnWidths: [CONTENT_W],
  rows: [new TableRow({ children: [new TableCell({ borders: noBorders, width: { size: CONTENT_W, type: WidthType.DXA },
    shading: { type: ShadingType.CLEAR, color: 'auto', fill: INK }, margins: { top: 50, bottom: 50, left: 140, right: 140 },
    children: [new Paragraph({ spacing: { before: 0, after: 0 }, children: [
      new TextRun({ text: 'SQLMigrationProject — Quick Reference   ', font: FONT, size: 28, bold: true, color: 'FFFFFF' }),
      new TextRun({ text: 'SQL Server → Aurora PostgreSQL · Amazon Redshift · Iceberg on S3 with Kiro  ·  8 skills · 8 steering files · 1 routing agent  ·  Windows · Linux · macOS  ·  September 2026', font: FONT, size: 15, color: 'CFE3E7' }),
    ] })] })] })] });

const doc = new Document({
  creator: 'SQLMigrationProject', title: 'SQLMigrationProject — Quick Reference',
  styles: { default: { document: { run: { font: FONT, size: SZ } } } },
  sections: [{
    properties: { page: { size: { width: PAGE_H, height: PAGE_W, orientation: PageOrientation.LANDSCAPE }, margin: { top: MARGIN, right: MARGIN, bottom: MARGIN, left: MARGIN } } },
    children: [titleBar, gap(36),
      new Table({ borders: tableNoBorders, layout: TableLayoutType.FIXED, width: { size: CONTENT_W, type: WidthType.DXA }, columnWidths: [COL_W, GAP, COL_W, GAP, COL_W],
        rows: [new TableRow({ children: [colCell(col1), gapCell(), colCell(col2), gapCell(), colCell(col3)] })] })],
  }],
});
Packer.toBuffer(doc).then((buf) => { fs.writeFileSync(OUT, buf); console.log('wrote', OUT, buf.length, 'bytes'); });
