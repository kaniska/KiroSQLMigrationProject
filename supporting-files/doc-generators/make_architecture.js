const fs = require('fs');
const {
  Document, Packer, Paragraph, TextRun, HeadingLevel, AlignmentType, Table, TableRow, TableCell,
  WidthType, ShadingType, BorderStyle, LevelFormat, Footer, PageNumber, TabStopType, Tab, TableLayoutType,
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
    layout: TableLayoutType.FIXED,
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

// ---------- diagram helpers (editable Word tables) ----------
const PAL = { user: 'E8EEF7', kiro: 'DCEBDD', skill: 'E3F1E0', tool: 'FFF1D6', data: 'EDE7F6', aws: 'FBE3D6', sec: 'FADBD8', grey: 'F2F2F2' };
function cell(text, fill, width, opts = {}) {
  return new TableCell({
    borders: opts.noBorder ? { top: { style: BorderStyle.NONE, size: 0, color: 'FFFFFF' }, bottom: { style: BorderStyle.NONE, size: 0, color: 'FFFFFF' }, left: { style: BorderStyle.NONE, size: 0, color: 'FFFFFF' }, right: { style: BorderStyle.NONE, size: 0, color: 'FFFFFF' } } : borders,
    width: { size: width, type: WidthType.DXA },
    columnSpan: opts.span,
    shading: fill ? { type: ShadingType.CLEAR, color: 'auto', fill } : undefined,
    margins: { top: 70, bottom: 70, left: 90, right: 90 },
    verticalAlign: 'center',
    children: String(text).split('\n').map((line, i) => new Paragraph({ alignment: AlignmentType.CENTER,
      children: runs(line, i === 0 ? { bold: !opts.plain, size: 19 } : { size: 17, color: '404040' }) })),
  });
}
// rows: [{label, fill, boxes:[text...]}] -> a layered block diagram with arrows between layers
function layers(rows, caption) {
  const LW = 1700, BW = TABLE_W - LW;
  const out = [];
  rows.forEach((r, i) => {
    const n = r.boxes.length, w = Math.floor(BW / n);
    out.push(new Table({ layout: TableLayoutType.FIXED, width: { size: TABLE_W, type: WidthType.DXA }, columnWidths: [LW, ...Array(n).fill(w)],
      rows: [new TableRow({ children: [cell(r.label, 'D9D9D9', LW), ...r.boxes.map((b) => cell(b, r.fill, w))] })] }));
    if (i < rows.length - 1) out.push(new Paragraph({ alignment: AlignmentType.CENTER, spacing: { before: 0, after: 0 },
      children: [t(r.arrow || '▼', { size: 18, color: '7F7F7F' })] }));
  });
  if (caption) out.push(new Paragraph({ children: [t(caption, { italics: true, size: 18, color: '595959' })], spacing: { before: 60, after: 200 } }));
  return out;
}
// steps: horizontal flow of boxes with arrows
function flow(items, fill, caption) {
  const n = items.length, arrowW = 300, w = Math.floor((TABLE_W - arrowW * (n - 1)) / n);
  const kids = [], widths = [];
  items.forEach((it, i) => {
    kids.push(cell(it, fill, w)); widths.push(w);
    if (i < n - 1) { kids.push(cell('→', null, arrowW, { noBorder: true, plain: true })); widths.push(arrowW); }
  });
  const out = [new Table({ layout: TableLayoutType.FIXED, width: { size: TABLE_W, type: WidthType.DXA }, columnWidths: widths, rows: [new TableRow({ children: kids })] })];
  if (caption) out.push(new Paragraph({ children: [t(caption, { italics: true, size: 18, color: '595959' })], spacing: { before: 60, after: 200 } }));
  return out;
}

// ---------- content ----------
const body = [
  new Paragraph({ children: [new TextRun({ text: 'SQL Server → Aurora PostgreSQL · Amazon Redshift · Iceberg on S3 with Kiro', font: FONT, size: 40, bold: true, color: ACCENT })], spacing: { after: 60 } }),
  new Paragraph({ children: [new TextRun({ text: 'Technical Architecture', font: FONT, size: 32, color: '404040' })], spacing: { after: 80 } }),
  new Paragraph({ children: [t('9 steering files · 8 skills · 2 agents · hooks · migkit governance layer · MCP (inbound + kit server) · AWS services · 694 tests — September 2026', { size: 20, color: '707070' })],
    border: { bottom: { style: BorderStyle.SINGLE, size: 8, color: ACCENT, space: 6 } }, spacing: { after: 240 } }),

  h1('1. Purpose and scope'),
  p('This document describes how the migration kit is built: the Kiro building blocks (steering, skills, two agents, hooks), the governance layer and deterministic tools, the knowledge the model uses, MCP integration (inbound servers and the kit\'s own placeholder server), the security architecture, audit and lineage, the optional AWS services with local fallback, the test architecture and the Windows readiness controls. The user guide explains how to **use** the kit; the README is the reference for commands.'),
  table([2600, 6426], ['Scope item', 'In this kit'], [
    ['Source', 'Microsoft SQL Server T-SQL (views, procedures, functions, triggers, DDL) as standalone `.sql` files or embedded in Informatica PowerCenter 10.x XML exports (`.prm` parameter files); report requests on the converted data; schema change templates (CSV/XLSX)'],
    ['Target', 'Amazon Aurora PostgreSQL 17.7 (skills run on PostgreSQL 15+) for procedural code; Amazon Redshift (RA3 / Serverless) for the warehouse; Apache Iceberg tables on S3 with the Glue Data Catalog, Athena engine v3 and Glue 5.x Spark jobs for the lake'],
    ['Runtime', 'Kiro IDE or Kiro CLI 2.x, Python 3, psql, AWS CLI v2; no third-party Python packages'],
    ['Analytics', 'Reporting and analytics SQL generated for PostgreSQL (executed), Amazon Redshift, Athena (Trino) over Iceberg and Spark SQL (dialect-checked, evidence runs on test resources)'],
    ['Building blocks', '9 steering files · 8 skills grouped by migration type and target · 2 agents (conversion, reporting) with Windows twins · guard and audit hooks · migkit (security, audit, services, governance contracts, DDL parser) · kit MCP server (placeholder)'],
    ['Principles', 'Behaviour parity (bugs preserved and flagged) · every result statically checked, tested or executed on a test target · decisions are asked, never guessed (stop codes) · deterministic controls outside the model · local-first, AWS-optional, nothing created in AWS'],
  ]),
  gap(),

  h1('2. Architecture overview'),
  ...layers([
    { label: 'People', fill: PAL.user, boxes: ['Migration engineer\nsql-migration-agent (IDE / kiro-cli)', 'Reporting analyst\nsql-reporting-agent', 'Batch operator\nsupporting-files/kiro_migrate.sh', 'Reviewer / security / integrator\nREADME, catalogs, audit log, kit MCP server'] },
    { label: 'Kiro agents', fill: PAL.kiro, boxes: ['sql-migration-agent (+ -windows)\nrouter: intake questions → skill · all 8 skills', 'sql-reporting-agent (+ -windows)\nreporting on 4 engines · read-only schema', 'Hooks (outside the model)\nagentSpawn · userPromptSubmit · preToolUse · postToolUse · stop'] },
    { label: 'Knowledge', fill: PAL.skill, boxes: ['Steering (always loaded, 9)\ngovernance · migration · redshift · iceberg · schema · reporting · informatica-etl · security · project', 'Skills (loaded on demand, 8)\nassessment · sql-conversion · redshift · iceberg · reporting · informatica · schema-conformance · change-propagation', 'MCP\ninbound: PostgreSQL · SQL Server · AWS Knowledge · AWS Docs (disabled)\noutbound placeholder: sqlmigration-kit'] },
    { label: 'Tools', fill: PAL.tool, boxes: ['Skill tools\nassess · redshift · iceberg · schema · change · infa_sql_tool · report_tool', 'Test engine\npgtest.sh · lib/*.sql · coverage · stub AWS CLI', 'migkit\nsecurity · audit · localdb · services · contract · ddl · platform_compat'] },
    { label: 'Data', fill: PAL.data, boxes: ['source/  generated/\nT-SQL · XML · PL/pgSQL · redshift/ · iceberg/ · reports/ · schema/ · changes/ (packages)', 'Aurora PostgreSQL 17 test DB (IAM)\nRedshift Data API · Athena / Glue (test names only, when configured)', 'logs/\naudit · state (lineage) · archive'] },
    { label: 'AWS (optional)', fill: PAL.aws, boxes: ['CloudWatch Logs', 'DataZone', 'Bedrock Guardrails', 'S3 Object Lock', 'Secrets Manager', 'Redshift Data API · Athena · Glue\nevidence on test resources'] },
  ], 'Figure 1 — Layers. Every box is an editable table cell; arrows show the direction of control.'),
  table([2400, 6626], ['Building block', 'Responsibility'], [
    ['Steering', 'What is correct: type and syntax maps, hard and parity rules, Informatica invariants, security rules, project values. Generic except `project.md`.'],
    ['Skills', 'How to do one unit of work and prove it: a numbered procedure, worked examples, corner-case catalogs, scripts and self-tests.'],
    ['Agents', 'Two assistants that package skills, steering, tools and permissions: `sql-migration-agent` routes conversion, schema and ETL work after intake questions; `sql-reporting-agent` writes and reviews reporting SQL. Both report in a fixed format with run id, stop codes and security findings.'],
    ['Governance layer', '`migkit/contract.py` (universal request/output contracts, statuses, stop codes, rule ledger, validation manifest V-001…V-040, packages with hashes) and `migkit/ddl.py` (multi-dialect DDL parser) shared by every skill.'],
    ['Hooks', 'Deterministic guardrails and audit that the model cannot override (exit code 2 blocks a tool call).'],
    ['migkit', 'Shared Python library (standard library only): scanner, safe XML parsing, hash-chained audit log, local JSON store, AWS services with fallback.'],
    ['Test engine', 'psql-based engine shared by all skills: guard, reset, assertions, report, coverage enforcement, security preflight, run-id tagging.'],
  ]),
  gap(),

  h1('3. Kiro building blocks'),
  h2('3.1 Steering'),
  table([2500, 1500, 5026], ['File', 'Inclusion', 'Content'], [
    ['`governance.md`', 'always', 'Universal request/output contracts, statuses GENERATED | PARTIAL | BLOCKED | VALIDATED, stop codes, M2RVE placement, rule ledger, validation manifest V-001…V-040, seven gates, skills grouped by migration type, intake questions [G-1–G-10]'],
    ['`migration.md`', 'always', 'Generic SQL Server → PostgreSQL rules: type map, syntax map, hard rules [H1–H17], parity rules [P1–P11], validation checklist, naming'],
    ['`redshift.md`', 'always', 'SQL Server → Amazon Redshift rules [R-1–R-15]: what Redshift lacks, kept functions, type map in bytes, DISTSTYLE/SORTKEY as decisions, informational keys, PL/pgSQL limits, MERGE limits, late-binding views, RLS, evidence'],
    ['`iceberg.md`', 'always', 'SQL Server → Iceberg / Athena / Glue / Spark rules [I-1–I-11]: spec types, partition transforms from design, two DDL dialects, schema evolution, function map, MERGE safety, views, jobs, evidence'],
    ['`schema.md`', 'always', 'Schema conformance [S-1–S-9] (snapshots, classifications, naming profiles, statuses, dry-run conformance, reference checks) and change propagation [S-10–S-13] (templates, protected layers, cast before rename, token-aware dry-run edits)'],
    ['`informatica-etl.md`', 'always', 'Where SQL lives in PowerCenter XML, invariants [IE-1–IE-13], connection/owner/datatype mapping, real export format, AWS SCT note, manual-review list'],
    ['`security.md`', 'always', 'Untrusted content, credentials, least privilege, AWS read-only, run id, audit evidence [S-1–S-11]'],
    ['`project.md`', 'always', 'This project: Aurora cluster and test database, layout, commands, AWS service status'],
  ]),
  gap(),
  h2('3.2 Skills'),
  table([2200, 3300, 3526], ['Skill', 'Procedure and references', 'Scripts and tests'], [
    ['`sql-conversion`', '10 steps; 17 worked examples; 87 corner cases (CC); MCP guide; unsupported features; security-logging catalog; AWS services guide', '`pgtest.sh`, `lib/` (guard, framework, static checks, report), `check_rule_coverage.py`, `migkit/`, 257 SQL + 33 unit tests'],
    ['`sql-reporting`', '7 steps + target step; 15 report patterns (RP); 24 query rules (RQ); 18 dialect rules (RD) with Redshift/Athena/Spark examples', 'report fixtures and tests, 88 SQL tests; `report_tool.py check --target`, 5 dialect tests'],
    ['`informatica-etl-conversion`', '6 steps; SQL locations map; 46 corner cases (IC) incl. Redshift/Iceberg targets; 5 example mappings; public corpus; per-target maps', '`infa_sql_tool.py` (`check --target`), fixtures, 29 unit + 38 SQL tests'],
    ['`migration-assessment`', '5 steps; placement matrix and complexity/tier table (MA-01..12); intake questions', '`assess_tool.py` (assess, inventory, validate, questions), 12 unit tests'],
    ['`sql-conversion-redshift`', '5 steps; 52 corner cases (RS); 5 worked pairs with a design file', '`redshift_tool.py` (convert-ddl, check, ledger, run via Redshift Data API, package), 13 unit tests incl. stub AWS CLI'],
    ['`sql-conversion-iceberg`', '5 steps; 51 corner cases (IB); 4 worked examples (DDL, Athena view, Spark SQL + Glue job, spatial)', '`iceberg_tool.py` (ddl, check, ledger, job, run via Athena, package), Glue job template, 10 unit tests'],
    ['`schema-conformance`', '5 steps; 22 rules (SC); type allowlists per target profile', '`schema_tool.py` (snapshot from DDL / live PostgreSQL / Glue, compare, conform, refs, package), 8 unit tests incl. project regression and live Aurora'],
    ['`schema-change-propagation`', '5 steps; 20 rules (CP); worked example (template, layers, policy, profile, flow)', '`change_tool.py` (ingest CSV/XLSX, validate, plan, patch, scan, package), 9 unit tests'],
  ]),
  gap(),
  p('Each `SKILL.md` has frontmatter `name` (equal to the folder name) and a `description` with trigger words; Kiro loads the skill when a request matches, or explicitly via `/skill-name`. The skills are grouped by migration type and target (`.kiro/steering/governance.md`); every cell of Figure 2 names the skill and the steering that applies.'),
  ...layers([
    { label: 'Any target', fill: PAL.kiro, boxes: ['Assessment (front door)\nmigration-assessment · governance.md', 'Schema governance\nschema-conformance · schema-change-propagation · schema.md', 'Agents\nsql-migration-agent (groups 1 + 3) · sql-reporting-agent (group 2)', 'Security + audit\nsecurity.md · GUARDRAILS.md'] },
    { label: 'Aurora PostgreSQL', fill: PAL.skill, boxes: ['Standalone SQL objects\nsql-conversion · migration.md', 'SQL inside Informatica ETL\ninformatica-etl-conversion --target postgres · pg_map.json', 'Reporting SQL\nsql-reporting --target postgres (executed) · reporting.md', 'Evidence\npgtest.sh on the Aurora test database'] },
    { label: 'Amazon Redshift', fill: PAL.skill, boxes: ['Standalone SQL objects\nsql-conversion-redshift · redshift.md', 'SQL inside Informatica ETL\ninformatica-etl-conversion --target redshift · redshift_map.json', 'Reporting SQL\nsql-reporting --target redshift · dialects.md', 'Evidence\nredshift_tool.py run (Data API, test DB names)'] },
    { label: 'Iceberg on S3', fill: PAL.skill, boxes: ['Standalone SQL objects\nsql-conversion-iceberg · iceberg.md', 'SQL inside Informatica ETL\ninformatica-etl-conversion --target iceberg · S3 landing + Glue MERGE job', 'Reporting SQL\nsql-reporting --target athena | spark · dialects.md', 'Evidence\niceberg_tool.py run (Athena, test DB names) · py_compile of jobs'] },
  ], 'Figure 2 — Skill map: migration type × target, with the steering file that governs each cell.'),
  h2('3.3 Agents'),
  table([2400, 6626], ['Agent', 'Role'], [
    ['`sql-migration-agent`', 'SQL conversion assistant: routes assessment, conversion of standalone and Informatica-embedded SQL to Aurora / Redshift / Iceberg, schema conformance and change propagation; loads all eight skills; writes under generated/, tests/, metadata/{migration_log.json,design,schema,changes}/, source/schema/, source/informatica/'],
    ['`sql-reporting-agent`', 'Reporting SQL assistant: report, dashboard and analytics SQL on PostgreSQL, Redshift, Athena/Iceberg and Spark; loads sql-reporting, read-only schema-conformance and the check/run commands of the Redshift and Iceberg tools; writes under generated/reports/, generated/schema/, tests/'],
    ['`*-windows`', 'Generated twins (make_windows_agent.py); same tools, resources, hooks and write paths; python -X utf8 / .cmd commands'],
    ['Tests', '`hooks/tests/test_agents.py` (AG-01…08: structure, resources, allow-lists vs workflow commands, write scope, separation of concerns, twins, kiro-cli validate, prompt/skill consistency); `supporting-files/verify_agents.sh [--smoke]`'],
  ]),
  gap(),
  table([2400, 6626], ['Agent field', 'Setting in `.kiro/agents/sql-migration-agent.json` (the reporting agent narrows every row to its scope)'], [
    ['prompt', '`file://./prompts/sql-migration-agent.md` — router: intake questions, skill table, chaining, stop codes as questions, workflows, guardrail behaviour, report format; `prompts/examples.md` lists prompts per skill'],
    ['resources', 'steering `file://.kiro/steering/**/*.md`, skills `skill://.kiro/skills/*/SKILL.md`, GUARDRAILS.md, security-logging.md, prompts/examples.md'],
    ['tools / allowedTools', 'fs_read, fs_write, execute_bash, grep, glob, MCP servers; auto-approved: reads and read-only MCP tools'],
    ['toolsSettings / permissions', 'shell allow-list (tests, the eight skill tools, read-only migkit commands, runner generators); writes only under generated/, tests/, metadata/{migration_log.json, design, schema, changes}/, source/schema/, source/informatica/'],
    ['hooks', 'agentSpawn (session run id, security notice, status), userPromptSubmit (hash only), preToolUse `*` (guard), postToolUse `*` (audit), stop (sync)'],
    ['mcpServers', 'five servers on the migration agent, three on the reporting agent — all `disabled: true` until enabled; `includeMcpJson: false`'],
  ]),
  gap(),

  h1('4. Knowledge the model uses'),
  p('Kiro builds the model context from three kinds of knowledge. Deterministic tools never depend on the model having read them; they enforce the critical parts again.'),
  ...layers([
    { label: 'Always in context', fill: PAL.kiro, boxes: ['Steering rules\n9 files (governance first)', 'Agent prompt\nrouter: intake questions · skill table · report format', 'Session notices\nrun id · security notice · migration status'] },
    { label: 'On demand', fill: PAL.skill, boxes: ['SKILL.md procedures\n8 skills', 'Catalogs\nCC · RQ/RP/RD · IC · MA · RS · IB · SC · CP · SEC/LOG/SVC/GOV · GRD/HOOK · AG · MCP', 'Worked examples\n17 T-SQL · 15 reports + 13 dialect ports · 5 mappings · 5 Redshift · 4 Iceberg · change flow'] },
    { label: 'External (optional)', fill: PAL.aws, boxes: ['AWS Knowledge MCP\nregional availability, docs', 'AWS Documentation MCP\nsearch · read', 'Database MCP\nlive schema · source procedure text'] },
  ], 'Figure 3 — Knowledge sources, from always-loaded to external.'),
  table([3000, 6026], ['Knowledge base', 'Used for'], [
    ['`references/examples/` (all skills)', 'Pattern templates; each is executed by the self-test, so templates are proven'],
    ['Corner-case catalogs', 'Risky constructs and their rule per target (CC PostgreSQL, RS Redshift, IB Iceberg/Athena/Spark, IC Informatica); `auto` rows must have a tagged test'],
    ['`governance.md`, `placement-matrix.md`', 'Contracts, statuses, stop codes, gates, M2RVE placement, complexity and review tiers — the questions the agent asks before converting'],
    ['`dialects.md` (sql-reporting)', 'How each report pattern is spelled on PostgreSQL, Redshift, Athena and Spark (RD-01…18)'],
    ['`AGENTS.md`, `prompts/examples.md`', 'What each agent does, how to run and test it, prompts per skill'],
    ['`informatica-etl-conversion/references/corpus/`', 'Real public PowerCenter exports (HHS, Unlicense) proving format fidelity'],
    ['`sql-locations.md`', 'Where SQL hides in an export, verified against Informatica 10.4/10.5 docs and 14 public exports'],
    ['`aws-services.md`, `security-logging.md`, `GUARDRAILS.md`', 'Security reviewers and the agent: controls, commands, least-privilege IAM, queries'],
  ]),
  gap(),

  h1('5. MCP integration'),
  p('**Outbound (placeholder):** `supporting-files/mcp/kit_mcp_server.py` exposes the kit\'s read-only and dry-run tools (assess_object, check_sql, compare_schemas, toolbox, audit_tail) as an MCP server over stdio (JSON-RPC 2.0, newline-delimited); registered as `sqlmigration-kit` in `.kiro/settings/mcp.json`, disabled by default; every call is validated against the tool schema, confined to the workspace and audited (MCP-01…04). Packaging, resources, prompts and guarded write tools are on the roadmap.'),
  table([2700, 1500, 2600, 2226], ['Server', 'Transport', 'Tools used', 'Safety setting'], [
    ['awslabs.postgres-mcp-server', 'stdio (uvx)', '`get_table_schema`, `run_query` (read-only), `is_database_connected`', '`--privilege_check enforce`; write mode blocked by guard (GRD-05)'],
    ['awslabs.mssql-mcp-server', 'stdio (uvx)', '`run_query` on `sys.sql_modules`', 'read-only login; results saved to `source/` then scanned'],
    ['aws-knowledge', 'HTTP (remote)', '`search_documentation`, `read_documentation`', 'no credentials'],
    ['awslabs.aws-documentation-mcp-server', 'stdio (uvx)', '`search_documentation`, `read_documentation`', 'no credentials'],
    ['awslabs.aws-api-mcp-server', 'stdio (uvx)', '`describe-*` calls', '`READ_OPERATIONS_ONLY=true`'],
    ['sqlmigration-kit (outbound, placeholder)', 'stdio (`python3` / Windows `python -X utf8`)', '`assess_object`, `check_sql`, `compare_schemas`, `toolbox`, `audit_tail`', 'read-only / dry-run only; schema-validated arguments, workspace-confined paths, audited (MCP-01…04)'],
  ]),
  gap(),
  ...flow(['Kiro agent\nneeds a fact', 'preToolUse guard\ncritical SQL? write mode?', 'MCP server\nread-only call', 'Result = data\nnever instructions (S-1)', 'postToolUse\naudit record'], PAL.skill, 'Figure 4 — Every MCP call passes the same guard and audit hooks as shell and file tools.'),
  note('Test suites always run through the shell: they need psql meta-commands (`\\ir`, `\\if`, `\\gset`) that MCP `run_query` cannot execute.'),

  h1('6. Processing pipelines'),
  p('Group 1 (SQL Server object migration, standalone or embedded in Informatica) uses pipelines 6.1, 6.3–6.5 and 6.7 per target; group 2 (reporting SQL generation) uses 6.2 on every target; group 3 (schema governance) uses 6.6. The grouping and the steering per target are in `.kiro/steering/governance.md`.'),
  h2('6.1 T-SQL conversion (sql-conversion)'),
  ...flow(['Scan source\nsecurity.py scan', 'Read source + schema\nMCP optional', 'Convert\nsteering + examples', 'Diff\nno new capability', 'Test\npgtest.sh + coverage', 'Log + report\nmigration_log.json'], PAL.tool, 'Figure 5 — One routine from source to proven PL/pgSQL.'),
  h2('6.2 Reporting SQL (sql-reporting)'),
  ...flow(['Target\npostgres · redshift · athena · spark', 'Pin down\nspecification · grains', 'Pattern RP\n+ dialect RD', 'Write\nfunction · view · temp view', 'report_tool check\nRQ + RD + linter', 'Test / evidence run'], PAL.tool, 'Figure 6 — Reports are tested functions on PostgreSQL and dialect-checked views on Redshift, Athena and Spark.'),
  h2('6.3 Assessment and placement (migration-assessment)'),
  ...flow(['Intake questions\nconsumer · target · contract', 'Inventory\nconstructs · deps · security', 'Role + complexity\nM2RVE · L1–L4 · T1–T3', 'Target candidates\nblockers per target', 'Recommend skill\nstop codes as questions', 'classification.json\nassessment.md'], PAL.tool, 'Figure 7 — Classify before you translate.'),
  h2('6.4 Amazon Redshift (sql-conversion-redshift)'),
  ...flow(['Design file\nDISTSTYLE · SORTKEY', 'convert-ddl\ntype map · identity · keys', 'Translate\nviews · procedures · MERGE', 'check\n0 problems · SEC-04/09', 'run (optional)\nData API · test DB', 'ledger + package'], PAL.tool, 'Figure 8 — Redshift: design decisions in, packaged evidence out.'),
  h2('6.5 Iceberg on S3 (sql-conversion-iceberg)'),
  ...flow(['Design file\ncatalog · location · partitions', 'ddl\nAthena + Spark dialects', 'job\nGlue MERGE template · py_compile', 'check\nSpark / Athena lint', 'run (optional)\nAthena · test DB', 'ledger + package'], PAL.tool, 'Figure 9 — Iceberg: table format decisions, jobs from a template.'),
  h2('6.6 Schema conformance and change propagation (schema-conformance, schema-change-propagation)'),
  ...flow(['snapshot\nDDL · live · Glue', 'compare\nEXACT … CONFLICT', 'conform\ndry-run DDL', 'refs\nreferences resolve', 'ingest → plan\ncast before rename', 'patch → scan\ndiff · rollback · package'], PAL.tool, 'Figure 10 — Schemas as hashed snapshots; changes as dry-run packages.'),
  h2('6.7 Informatica PowerCenter XML (informatica-etl-conversion)'),
  ...flow(['extract\nsafe parse · scan · manifest', 'convert\nSQL files', 'check\ninvariants · SEC', 'inject --map\nintegrity · lineage', 'render\nsafe params', 'test\nPostgreSQL'], PAL.tool, 'Figure 11 — The tool does everything that must be exact; the model converts the SQL.'),
  table([2600, 6426], ['Design decision', 'Reason'], [
    ['Edit XML as text, only matched `VALUE` attributes', 'Everything else stays byte-identical, including ISO-8859-1/Windows-1252 encoding, CRLF and `NAME ="…"` spacing of real exports'],
    ['Converted values written in the source entity style', '`&#xD;&#xA;`, `&apos;`, `&#x5c;`; characters outside the code page as numeric references'],
    ['Structural integrity check after inject', 'Only injected values and `--map` attributes may differ; `CRCVALUE` elements must not change'],
    ['Source SHA-256 in `manifest.json`', 'Inject refuses if the export changed after extraction'],
    ['Render to temp views and `pg_temp` functions', 'Converted SQL runs on a test database with real parameter values, side effects checked'],
  ]),
  gap(),

  h1('7. Security architecture'),
  p('Threat model: source scripts, XML exports, parameter files, pasted text and MCP results are untrusted. They may carry prompt injection, hidden Unicode, credentials, XML attacks or SQL that would be dangerous to execute. The agent itself may be steered into unsafe actions. Controls are layered and deterministic.'),
  ...layers([
    { label: '1 Input', fill: PAL.sec, boxes: ['Scanner SEC-01..05, 10\ninjection · hidden · secrets · dangerous SQL', 'Safe XML SEC-06, 11\nno entities / DTD subset / remote DTD', 'Session notice\nagentSpawn lists findings'] },
    { label: '2 Agents', fill: PAL.sec, boxes: ['Allow-lists per agent\ncommands · write paths · separation of concerns AG-05', 'preToolUse guard GRD-01..12\nexit 2 blocks; fail closed', 'Steering S-1..S-11 · G-10\nbehaviour rules · production out of reach'] },
    { label: '3 Tools', fill: PAL.sec, boxes: ['Conversion diff SEC-09\nno new capability', 'Values and paths SEC-07/08', 'Integrity + CRCVALUE\nIC-43', 'Test-name gate + scan before execution\nRedshift Data API · Athena · Glue (RS-70, IB-80, SC-02); no apply (CP-25)'] },
    { label: '4 Tests / DB', fill: PAL.sec, boxes: ['Preflight SEC-12\nshell escapes · secrets', 'Test-DB guard\nname · no superuser', 'IAM auth\n15-minute tokens'] },
    { label: '5 Evidence', fill: PAL.data, boxes: ['Redaction LOG-04', 'Hash chain LOG-03', 'Bedrock Guardrails SEC-13\nwhen configured', 'S3 Object Lock\nwhen configured'] },
  ], 'Figure 12 — Defence in depth: each layer works even if the one above is bypassed.'),
  table([2800, 6226], ['OWASP LLM Top 10 risk', 'Controls'], [
    ['LLM01 Prompt injection', 'SEC-01/02 scanning, session and prompt notices, S-1 steering, GRD-10 on writes, Bedrock PROMPT_ATTACK filter (SEC-13)'],
    ['LLM02 Sensitive information disclosure', 'SEC-03, GRD-01 credential access blocks, audit redaction, prompts logged as hashes, Secrets Manager injection without printing'],
    ['LLM05 Improper output handling', 'SEC-09 diff, GRD-11, Informatica inject refusal, render value checks (SEC-08), test preflight'],
    ['LLM06 Excessive agency', 'Per-agent allow-lists, GRD-03/04/05/06/07/08/12, AWS read-only, test databases only (PostgreSQL, Redshift, Athena, Glue), no superuser, nothing applied to a live target'],
  ]),
  gap(),
  table([1400, 1300, 6326], ['Exit code', 'From', 'Meaning'], [
    ['2', 'hook', 'preToolUse guard blocked the tool call; reason on stderr to the agent'],
    ['3', 'skill tools', 'refused: security guardrail (XML, conversion, value, path), non-test database, or a production write (`change_tool.py --apply`)'],
    ['4', 'pgtest.sh', 'refused by the test preflight'],
    ['1', 'check / tests', 'a check or test failed'],
  ]),
  gap(),

  h1('8. Audit, correlation and lineage'),
  ...flow(['run_tests.sh / agentSpawn\nnew run id', 'MIGRATION_RUN_ID\n+ TRACEPARENT to children', 'tools · hooks · MCP calls\naudit records', 'PostgreSQL application_name\nRedshift / Athena client tokens', 'OpenLineage event\nrun facet with run id'], PAL.data, 'Figure 13 — One W3C trace id links the Kiro session, tools, database and warehouse statements and lineage.'),
  table([2600, 6426], ['Audit record field', 'Content'], [
    ['timestamp', 'RFC 3339 UTC with milliseconds'],
    ['severity_text / severity_number', 'OpenTelemetry severities (INFO 9, WARN 13, ERROR 17)'],
    ['event, body, attributes', 'dotted event name; redacted, length-capped values'],
    ['run_id = trace_id, span_id, parent_span_id, traceparent', 'W3C Trace Context; an X-Ray id `1-<8>-<24>` can be derived from the same value'],
    ['resource', 'service.name, service.version, host.name, user.name, process.pid'],
    ['seq, prev_hash, hash', 'SHA-256 chain per daily file; `audit.py verify` detects edits, deletions, reordering'],
  ]),
  gap(),
  p('**Informatica lineage attributes:** folder, scope, mapping or session, instance, attribute, tag index, kind, SHA-256 of the source value and of the converted value. `inject` emits an OpenLineage `RunEvent` (job namespace `informatica://<repository>`, inputs: source XML and SQL Server tables, outputs: converted XML and PostgreSQL tables).'),
  p('**Database side:** `application_name`, the setting `migration.run_id` and `test_results.run_id`; with pgaudit and `log_line_prefix %a` on a custom Aurora parameter group, CloudWatch Logs searches by run id reach the SQL itself.'),

  h1('9. AWS service integration with local fallback'),
  ...layers([
    { label: 'Configuration', fill: PAL.grey, boxes: ['defaults', 'migration-services.json', 'MIGRATION_OFFLINE=1', 'MIGRATION_<CONCERN>_BACKEND'], arrow: '▼  later wins' },
    { label: 'Resolution', fill: PAL.tool, boxes: ['local\nnever call AWS', 'auto\nprobe (cached) → AWS or local + services.fallback', 'aws\nprobe must pass, else fail loudly'] },
    { label: 'Back ends', fill: PAL.aws, boxes: ['audit → CloudWatch Logs\nor logs/audit', 'lineage → DataZone\nor logs/state', 'guardrail → Bedrock\n+ local scan', 'archive → S3\n+ logs/archive', 'secrets → Secrets Manager\nor IAM / env'] },
  ], 'Figure 14 — Each concern resolves independently; a missing or denied service never stops a migration in auto mode.'),
  table([2000, 3300, 3726], ['Concern', 'AWS API (read-only probe · write)', 'Limits and behaviour'], [
    ['audit', '`DescribeLogGroups` · `CreateLogStream`, `PutLogEvents`', 'stream per day/host; batches ≤ 1,048,576 bytes (26 bytes/event overhead), ≤ 10,000 events, ≤ 24 h, chronological; files > 14 days stay local; per-file offsets'],
    ['lineage', '`GetDomain` · `PostLineageEvent`', 'OpenLineage ≤ 300,000 bytes; client token = local document id; pending until sent'],
    ['guardrail', '`GetGuardrail` · `ApplyGuardrail` (source INPUT)', 'chunked, per-run character budget; matched sensitive values never stored'],
    ['archive', '`HeadBucket` · `PutObject`', 'SHA-256 checksum, SSE-KMS, Object Lock retention; local copy with manifest'],
    ['secrets', '`DescribeSecret` · `GetSecretValue`', 'PG* variables injected into a child process only'],
    ['evidence (Redshift, Athena, Glue)', '`redshift-data batch-execute-statement` / `describe-statement` · `athena start-query-execution` / `get-query-execution` · `glue get-tables`', 'only databases whose name contains test/dev/sandbox/local, after a security scan; idempotent client tokens carry the run id; ≤ 200 KB per Data API request; exercised through the stub AWS CLI in the self-tests; never creates workgroups, databases, tables or jobs'],
  ]),
  gap(),
  note('The kit calls the AWS CLI with timeouts and never creates AWS resources. Setup commands and the least-privilege IAM policy are in `references/aws-services.md`.'),

  h1('10. Test architecture'),
  ...layers([
    { label: 'Engine', fill: PAL.tool, boxes: ['preflight\nSEC-12', 'guard_and_reset\ntest DB · no superuser · run id', 'framework\nassert equal/true/raises/sqlstate', 'report\nsummary · exit code · results file'] },
    { label: 'Suites', fill: PAL.skill, boxes: ['project suites\n153', 'sql-conversion\n257 SQL', 'sql-reporting\n88 SQL', 'informatica\n38 SQL'] },
    { label: 'Unit / hooks', fill: PAL.kiro, boxes: ['migkit + governance\n41 (stub AWS CLI)', 'infa_sql_tool\n29 · report dialects 5', 'assessment · Redshift · Iceberg · schema · change\n12 · 13 · 10 · 8 · 9', 'agent hooks 19\nagents 8 · MCP 4'] },
    { label: 'Coverage gate', fill: PAL.data, boxes: ['H · P · CC', 'RQ · RP · RD', 'IC', 'SEC · LOG · SVC · GOV', 'MA · RS · IB · SC · CP', 'GRD · HOOK · AG · MCP'] },
  ], 'Figure 15 — 694 checks; every catalog row marked auto must be covered by a tagged test.'),
  table([2800, 6226], ['Test type', 'What it proves'], [
    ['Behaviour / parity tests', 'Converted routines return the same results as the source, including preserved bugs'],
    ['Worked-example tests', 'Every example in every skill runs on PostgreSQL, so templates are correct'],
    ['Corner-case tests', 'One or more tagged tests per risky construct (CC, IC)'],
    ['Report correctness tests', 'Hand-computed numbers for each pattern and rule (RP, RQ)'],
    ['Static checks', 'Leftover T-SQL, duplicate names, COMMIT in functions, volatility, money columns'],
    ['Regeneration and round-trip', 'Converted XML is reproducible; unchanged exports (including public corpus) round-trip byte for byte'],
    ['Security negative tests', 'Billion laughs, XXE, injection, hidden characters, secrets, dangerous conversions, value breakout, path traversal, preflight refusal'],
    ['Audit and lineage tests', 'Record format, correlation, redaction, hash chain, concurrency, spans, OpenLineage content'],
    ['Service tests with a stub AWS CLI', 'Fallback, fail-loud mode, batching limits, idempotent lineage, guardrail parsing, Object Lock, secret injection'],
    ['Hook tests', 'Each guardrail blocks its cases and allows the normal workflow; audit hooks never break a session'],
    ['Engine correlation tests', 'Run id and application_name visible in PostgreSQL and on every result'],
    ['Coverage enforcement', '`check_rule_coverage.py` fails the run when a rule has no test'],
  ]),
  gap(),

  h1('11. Operations'),
  table([3400, 5626], ['Task', 'Command or setting'], [
    ['Full verification', '`bash supporting-files/run_tests.sh` (`--project`, `--skill`; `TEST_TARGET=local`)'],
    ['Batch migration', '`bash supporting-files/kiro_migrate.sh` (scans inputs, batch run id, archive, sync)'],
    ['Service status', '`python3 …/migkit/services.py status | probe --refresh | sync`'],
    ['Audit trail', '`python3 …/migkit/audit.py tail --run <run8>` · `verify`'],
    ['Environment', '`MIGRATION_RUN_ID`, `MIGRATION_OFFLINE`, `MIGRATION_<CONCERN>_BACKEND`, `MIGRATION_LOG_DIR`, `MIGRATION_STATE_DIR`, `MIGRATION_MAX_INPUT_BYTES`, `PG_IAM_AUTH`, `PG_SECRET_FROM_SERVICES`'],
    ['Local-only overrides', '`PGTEST_ALLOW_SUPERUSER=1`, `PGTEST_ALLOW_DANGEROUS=1` (blocked for the agents)'],
    ['Agents', '`bash supporting-files/verify_agents.sh [--smoke]` — structural tests AG-01…08, `kiro-cli agent validate` for all four files, workspace listing, optional read-only headless prompt per agent'],
    ['Windows readiness', '`python3 supporting-files/check_windows_readiness.py` (HOOK-06) · `make_skill_runners.py --check` · `make_windows_agent.py --check`'],
    ['Kit as an MCP server', '`python3 supporting-files/mcp/kit_mcp_server.py --list`; enable `sqlmigration-kit` (or `-windows`) in `.kiro/settings/mcp.json`'],
    ['Evidence on Redshift / Athena', '`REDSHIFT_DATABASE` + `REDSHIFT_WORKGROUP` (or `REDSHIFT_CLUSTER`), `ATHENA_DATABASE` (+ `ATHENA_WORKGROUP`, `ATHENA_OUTPUT_LOCATION`) — test names only; unset = static checks and stub AWS CLI'],
  ]),
  gap(),

  h1('12. Platforms and packaging'),
  table([2600, 3200, 3226], ['Concern', 'Linux / macOS', 'Windows'], [
    ['Scripts', '`*.sh` (bash)', '`*.ps1` (PowerShell 5.1+ / 7) with a `.cmd` launcher, same arguments; shared helpers in `winlib.ps1`'],
    ['Python', '`python3`', '`python` or `py -3`; `PYTHONUTF8=1`, hooks run `python -X utf8`'],
    ['Agents', '`sql-migration-agent`, `sql-reporting-agent`', '`*-windows` twins generated by `make_windows_agent.py`, checked for drift (AG-06, HOOK-05)'],
    ['Skill runners', 'hand-written `run_skill_tests.sh` (PostgreSQL steps) or `skill.runner.json`', 'generated `.ps1`/`.cmd` twins (`make_skill_runners.py`) for Python-only skills; hand-written twins for the PostgreSQL ones'],
    ['Tool lookup', '`psql`, `aws` on `PATH`', '`psql.exe` / `aws.exe` found under `Program Files` when not on `PATH` (`platform_compat.find_executable`, `Find-MigPsql`)'],
    ['MCP server', '`python3 supporting-files/mcp/kit_mcp_server.py`', '`sqlmigration-kit-windows` entry (`python -X utf8`); UTF-8, LF-delimited messages on every platform'],
    ['File locks', '`fcntl.flock`', '`msvcrt.locking` on a sidecar `.lock` file'],
    ['Text I/O', 'UTF-8, LF', 'UTF-8 forced (stdin, stdout, files); XML keeps its own encoding and CRLF'],
    ['Guard hook', 'bash forms of each rule', 'PowerShell and cmd.exe forms (`iwr | iex`, `Remove-Item -Recurse`, `$env:…=`, `aws.exe`, `psql.exe`), `\\` paths normalised'],
    ['Line endings', '`.gitattributes`: `.sh` LF', '`.cmd` / `.ps1` CRLF; XML and `.prm` never converted'],
  ]),
  gap(),
  p('**Packaging:** `package.sh` / `package.cmd` run `package.py`. It clears hidden flags on `.kiro` (the name itself is required by Kiro) and zips the workspace with `.kiro` first. Bytes, line endings and executable bits are kept, and the archive is verified to contain the steering files, every `SKILL.md`, all four agent files and the settings.md`, both agents and the settings. Runtime `logs/` are excluded by default.'),
  p('**Parity (HOOK-05) and readiness (HOOK-06):** every `.sh` must have a `.ps1` twin and a `.cmd` launcher with the right line endings and a UTF-8 BOM, and the Windows agents must match the generated ones; `check_windows_readiness.py` additionally verifies balanced PowerShell syntax, that referenced files exist, that hand-written twins run the same tests, catalogs and rule prefixes as their `.sh`, and that `mcp.json` has Windows variants. Both run inside `run_tests.sh`. The PowerShell scripts have been verified statically on macOS; the open item to execute them once on a Windows machine is tracked in the README.'),

  h1('13. Roadmap'),
  table([1700, 7326], ['Stage', 'Skills'], [
    ['Delivered', 'SQL Server → Aurora PostgreSQL (T-SQL code and DDL) · reporting and analytics SQL on PostgreSQL, Redshift, Athena and Spark · Informatica ETL with SQL Server SQL → PostgreSQL, Redshift or the Iceberg lake · migration assessment and placement · SQL Server → Amazon Redshift · SQL Server → Iceberg on S3 (Athena / Glue / Spark) · schema gap analysis and conformance · schema change propagation · governance layer · two agents (conversion, reporting) · MCP server placeholder'],
    ['Next', 'Data validation at a consistent snapshot on all targets (row counts, key sets, checksums, sample diffs — V-012…V-021 executed) · Redshift Spectrum and Redshift-managed Iceberg tables as a serving path · Glue Data Catalog multi-dialect views · live evidence runs once Redshift/Athena test resources exist'],
    ['AI-DLC integration (placeholder)', 'Map the seven gates and the packages onto the AI-Driven Development Lifecycle (AWS, 2025): Inception = assessment and placement packages, Construction = conversion / conformance / change units of work with the rule ledger as the reviewable artifact, Operations = evidence runs and audit sync. Expected form: a steering file (`.kiro/steering/aidlc.md`, the open-sourced AI-DLC workflows ship as Kiro steering) plus a package → unit-of-work adapter. Not started.'],
    ['Later', 'SQL Server stored procedures → Oracle (PL/SQL) · Informatica ETL → Redshift and Oracle'],
  ]),
  gap(),
  p('Each new target is a steering file, a skill with examples and a catalog, and tagged tests. They reuse the agent, the guardrail hooks, migkit (security, audit, lineage, AWS services), the test engine and the coverage gate.'),

  h1('14. Reuse and extension'),
  bullet('Copy the steering files (`governance.md` first) and the skill folders; `sql-conversion` is required by the others (shared engine, migkit, governance layer, DDL parser).'),
  bullet('Write a project-specific `project.md`; keep the other steering files generic.'),
  bullet('Add a skill: `SKILL.md` + references + a catalog with ids + tagged tests + `run_skill_tests.sh` + `skill.runner.json` (Windows twins are generated by `supporting-files/make_skill_runners.py`), then register it in `supporting-files/run_tests.sh` / `.ps1` and in the agent allow-lists.'),
  bullet('Add a guardrail: a GRD row in `GUARDRAILS.md`, the rule in `guard_tool.py`, and positive and negative tests.'),
  bullet('Add an AWS back end: a concern in `services.py` (probe, write, fallback), a SVC row and stub-CLI tests.'),

  h1('15. Open items'),
  p('Current open items are tracked in `README.md` section 15: AWS access (root keys → IAM role) and evidence resources; Redshift / Athena **test** resources for live evidence runs (the kit never creates them); warehouse and lake design decisions (`metadata/design/*.json`) and identity mappings for security-bearing views; the Aurora parameter group; business decisions on six flagged objects; Informatica follow-ups outside the XML; the first execution of the Windows scripts on a Windows machine; packaging the kit MCP server; the AI-DLC integration placeholder; Kiro CLI 3.0 hooks.'),
];
const doc = new Document({
  creator: 'SQLMigrationProject',
  title: 'SQL Server to Aurora PostgreSQL, Amazon Redshift and Iceberg on S3 with Kiro — Technical Architecture',
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
    properties: { page: { size: { width: 11906, height: 16838 }, margin: { top: 1440, right: 1440, bottom: 1440, left: 1440 } } },
    footers: { default: new Footer({ children: [new Paragraph({
      tabStops: [{ type: TabStopType.RIGHT, position: TABLE_W }],
      children: [t('SQL Server → Aurora PostgreSQL · Amazon Redshift · Iceberg on S3 · Technical Architecture', { size: 16, color: '808080' }),
                 new TextRun({ children: [new Tab(), 'Page '], font: FONT, size: 16, color: '808080' }),
                 new TextRun({ children: [PageNumber.CURRENT], font: FONT, size: 16, color: '808080' })] })] }) },
    children: body,
  }],
});

Packer.toBuffer(doc).then((buf) => { fs.writeFileSync(OUT, buf); console.log('wrote', OUT, buf.length, 'bytes'); });
