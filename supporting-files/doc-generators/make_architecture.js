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
  new Paragraph({ children: [new TextRun({ text: 'SQL Server → Aurora PostgreSQL with Kiro', font: FONT, size: 44, bold: true, color: ACCENT })], spacing: { after: 60 } }),
  new Paragraph({ children: [new TextRun({ text: 'Technical Architecture', font: FONT, size: 32, color: '404040' })], spacing: { after: 80 } }),
  new Paragraph({ children: [t('steering · skills · agent · hooks · migkit · MCP · AWS services · tests — September 2026', { size: 20, color: '707070' })],
    border: { bottom: { style: BorderStyle.SINGLE, size: 8, color: ACCENT, space: 6 } }, spacing: { after: 240 } }),

  h1('1. Purpose and scope'),
  p('This document describes how the migration kit is built: the Kiro building blocks (steering, skills, agent, hooks), the deterministic tools, the knowledge the model uses, MCP integration, the security architecture, audit and lineage, the optional AWS services with local fallback, and the test architecture. The user guide explains how to **use** the kit; the README is the reference for commands.'),
  table([2600, 6426], ['Scope item', 'In this kit'], [
    ['Source', 'Microsoft SQL Server T-SQL (procedures, functions, triggers, DDL), reports on top of it, Informatica PowerCenter 10.x XML exports with embedded SQL Server SQL, `.prm` parameter files'],
    ['Target', 'Amazon Aurora PostgreSQL 17.7 (skills run on PostgreSQL 15+)'],
    ['Runtime', 'Kiro IDE or Kiro CLI 2.x, Python 3, psql, AWS CLI v2; no third-party Python packages'],
    ['Principles', 'Behaviour parity (bugs preserved and flagged) · every result proven on a test database · deterministic controls outside the model · local-first, AWS-optional'],
  ]),
  gap(),

  h1('2. Architecture overview'),
  ...layers([
    { label: 'People', fill: PAL.user, boxes: ['Migration engineer\nKiro IDE chat / kiro-cli chat', 'Batch operator\nsupporting-files/kiro_migrate.sh', 'Reviewer / security\nREADME, catalogs, audit log'] },
    { label: 'Kiro agent', fill: PAL.kiro, boxes: ['sql-migration-agent\nprompt · tools · allow-lists · resources', 'Hooks (outside the model)\nagentSpawn · userPromptSubmit · preToolUse · postToolUse · stop'] },
    { label: 'Knowledge', fill: PAL.skill, boxes: ['Steering (always loaded)\nmigration · informatica-etl · security · project', 'Skills (loaded on demand)\nsql-conversion · sql-reporting · informatica-etl-conversion', 'MCP (optional)\nPostgreSQL · SQL Server · AWS Knowledge · AWS Docs'] },
    { label: 'Tools', fill: PAL.tool, boxes: ['infa_sql_tool.py\nextract · check · inject · render', 'Test engine\npgtest.sh · lib/*.sql · coverage', 'migkit\nsecurity · audit · localdb · services'] },
    { label: 'Data', fill: PAL.data, boxes: ['source/  generated/\nT-SQL · XML · PL/pgSQL', 'Aurora PostgreSQL 17\ntest database (IAM auth)', 'logs/\naudit · state (lineage) · archive'] },
    { label: 'AWS (optional)', fill: PAL.aws, boxes: ['CloudWatch Logs', 'DataZone', 'Bedrock Guardrails', 'S3 Object Lock', 'Secrets Manager'] },
  ], 'Figure 1 — Layers. Every box is an editable table cell; arrows show the direction of control.'),
  table([2400, 6626], ['Building block', 'Responsibility'], [
    ['Steering', 'What is correct: type and syntax maps, hard and parity rules, Informatica invariants, security rules, project values. Generic except `project.md`.'],
    ['Skills', 'How to do one unit of work and prove it: a numbered procedure, worked examples, corner-case catalogs, scripts and self-tests.'],
    ['Agent', 'Packages skills, steering, tools and permissions for end-to-end work; reports in a fixed format including run id and security findings.'],
    ['Hooks', 'Deterministic guardrails and audit that the model cannot override (exit code 2 blocks a tool call).'],
    ['migkit', 'Shared Python library (standard library only): scanner, safe XML parsing, hash-chained audit log, local JSON store, AWS services with fallback.'],
    ['Test engine', 'psql-based engine shared by all skills: guard, reset, assertions, report, coverage enforcement, security preflight, run-id tagging.'],
  ]),
  gap(),

  h1('3. Kiro building blocks'),
  h2('3.1 Steering'),
  table([2500, 1500, 5026], ['File', 'Inclusion', 'Content'], [
    ['`migration.md`', 'always', 'Generic SQL Server → PostgreSQL rules: type map, syntax map, hard rules [H1–H17], parity rules [P1–P11], validation checklist, naming'],
    ['`informatica-etl.md`', 'always', 'Where SQL lives in PowerCenter XML, invariants [IE-1–IE-13], connection/owner/datatype mapping, real export format, AWS SCT note, manual-review list'],
    ['`security.md`', 'always', 'Untrusted content, credentials, least privilege, AWS read-only, run id, audit evidence [S-1–S-11]'],
    ['`project.md`', 'always', 'This project: Aurora cluster and test database, layout, commands, AWS service status'],
  ]),
  gap(),
  h2('3.2 Skills'),
  table([2200, 3300, 3526], ['Skill', 'Procedure and references', 'Scripts and tests'], [
    ['`sql-conversion`', '10 steps; 17 worked examples; 87 corner cases (CC); MCP guide; unsupported features; security-logging catalog; AWS services guide', '`pgtest.sh`, `lib/` (guard, framework, static checks, report), `check_rule_coverage.py`, `migkit/`, 257 SQL + 33 unit tests'],
    ['`sql-reporting`', '7 steps; 15 report patterns (RP); 24 query rules (RQ)', 'report fixtures and tests, 88 SQL tests'],
    ['`informatica-etl-conversion`', '6 steps; SQL locations map; 44 corner cases (IC); 5 example mappings; public corpus', '`infa_sql_tool.py`, fixtures, 27 unit + 38 SQL tests'],
    ['`schema-validation`, `metadata-validation`', 'planned (stubs)', '—'],
  ]),
  gap(),
  p('Each `SKILL.md` has frontmatter `name` (equal to the folder name) and a `description` with trigger words; Kiro loads the skill when a request matches, or explicitly via `/skill-name`.'),
  h2('3.3 Agent'),
  table([2400, 6626], ['Agent field', 'Setting in `.kiro/agents/sql-migration-agent.json`'], [
    ['prompt', '`file://./prompts/sql-migration-agent.md` — workflows, guardrail behaviour, report format'],
    ['resources', 'steering `file://.kiro/steering/**/*.md`, skills `skill://.kiro/skills/*/SKILL.md`, GUARDRAILS.md, security-logging.md'],
    ['tools / allowedTools', 'fs_read, fs_write, execute_bash, grep, glob, MCP servers; auto-approved: reads and read-only MCP tools'],
    ['toolsSettings / permissions', 'shell allow-list (tests, skill tools, read-only migkit commands); writes only under generated/, tests/, metadata/migration_log.json, source/schema/, source/informatica/'],
    ['hooks', 'agentSpawn (session run id, security notice, status), userPromptSubmit (hash only), preToolUse `*` (guard), postToolUse `*` (audit), stop (sync)'],
    ['mcpServers', 'five servers, all `disabled: true` until enabled; `includeMcpJson: false`'],
  ]),
  gap(),

  h1('4. Knowledge the model uses'),
  p('Kiro builds the model context from three kinds of knowledge. Deterministic tools never depend on the model having read them; they enforce the critical parts again.'),
  ...layers([
    { label: 'Always in context', fill: PAL.kiro, boxes: ['Steering rules\n4 files', 'Agent prompt\nworkflows · report format', 'Session notices\nrun id · security notice · status'] },
    { label: 'On demand', fill: PAL.skill, boxes: ['SKILL.md procedures\n3 skills', 'Catalogs\nCC · RQ/RP · IC · SEC/LOG/SVC · GRD', 'Worked examples\n17 T-SQL · 15 reports · 5 mappings'] },
    { label: 'External (optional)', fill: PAL.aws, boxes: ['AWS Knowledge MCP\nregional availability, docs', 'AWS Documentation MCP\nsearch · read', 'Database MCP\nlive schema · source procedure text'] },
  ], 'Figure 2 — Knowledge sources, from always-loaded to external.'),
  table([3000, 6026], ['Knowledge base', 'Used for'], [
    ['`references/examples/` (all skills)', 'Pattern templates; each is executed by the self-test, so templates are proven'],
    ['Corner-case catalogs', 'Risky constructs and their rule; `auto` rows must have a tagged test'],
    ['`informatica-etl-conversion/references/corpus/`', 'Real public PowerCenter exports (HHS, Unlicense) proving format fidelity'],
    ['`sql-locations.md`', 'Where SQL hides in an export, verified against Informatica 10.4/10.5 docs and 14 public exports'],
    ['`aws-services.md`, `security-logging.md`, `GUARDRAILS.md`', 'Security reviewers and the agent: controls, commands, least-privilege IAM, queries'],
  ]),
  gap(),

  h1('5. MCP integration'),
  table([2700, 1500, 2600, 2226], ['Server', 'Transport', 'Tools used', 'Safety setting'], [
    ['awslabs.postgres-mcp-server', 'stdio (uvx)', '`get_table_schema`, `run_query` (read-only), `is_database_connected`', '`--privilege_check enforce`; write mode blocked by guard (GRD-05)'],
    ['awslabs.mssql-mcp-server', 'stdio (uvx)', '`run_query` on `sys.sql_modules`', 'read-only login; results saved to `source/` then scanned'],
    ['aws-knowledge', 'HTTP (remote)', '`search_documentation`, `read_documentation`', 'no credentials'],
    ['awslabs.aws-documentation-mcp-server', 'stdio (uvx)', '`search_documentation`, `read_documentation`', 'no credentials'],
    ['awslabs.aws-api-mcp-server', 'stdio (uvx)', '`describe-*` calls', '`READ_OPERATIONS_ONLY=true`'],
  ]),
  gap(),
  ...flow(['Kiro agent\nneeds a fact', 'preToolUse guard\ncritical SQL? write mode?', 'MCP server\nread-only call', 'Result = data\nnever instructions (S-1)', 'postToolUse\naudit record'], PAL.skill, 'Figure 3 — Every MCP call passes the same guard and audit hooks as shell and file tools.'),
  note('Test suites always run through the shell: they need psql meta-commands (`\\ir`, `\\if`, `\\gset`) that MCP `run_query` cannot execute.'),

  h1('6. Processing pipelines'),
  h2('6.1 T-SQL conversion (sql-conversion)'),
  ...flow(['Scan source\nsecurity.py scan', 'Read source + schema\nMCP optional', 'Convert\nsteering + examples', 'Diff\nno new capability', 'Test\npgtest.sh + coverage', 'Log + report\nmigration_log.json'], PAL.tool, 'Figure 4 — One routine from source to proven PL/pgSQL.'),
  h2('6.2 Reporting SQL (sql-reporting)'),
  ...flow(['Pin down\nspecification', 'Schema grains', 'Pattern RP', 'Write function\nread-only', 'Check numbers\nRQ rules', 'Test + deliver'], PAL.tool, 'Figure 5 — Reports are tested functions on the converted schema.'),
  h2('6.3 Informatica PowerCenter XML (informatica-etl-conversion)'),
  ...flow(['extract\nsafe parse · scan · manifest', 'convert\nSQL files', 'check\ninvariants · SEC', 'inject --map\nintegrity · lineage', 'render\nsafe params', 'test\nPostgreSQL'], PAL.tool, 'Figure 6 — The tool does everything that must be exact; the model converts the SQL.'),
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
    { label: '2 Agent', fill: PAL.sec, boxes: ['Allow-lists\ncommands · write paths', 'preToolUse guard GRD-01..11\nexit 2 blocks; fail closed', 'Steering S-1..S-11\nbehaviour rules'] },
    { label: '3 Tools', fill: PAL.sec, boxes: ['Conversion diff SEC-09\nno new capability', 'Values and paths SEC-07/08', 'Integrity + CRCVALUE\nIC-43'] },
    { label: '4 Tests / DB', fill: PAL.sec, boxes: ['Preflight SEC-12\nshell escapes · secrets', 'Test-DB guard\nname · no superuser', 'IAM auth\n15-minute tokens'] },
    { label: '5 Evidence', fill: PAL.data, boxes: ['Redaction LOG-04', 'Hash chain LOG-03', 'Bedrock Guardrails SEC-13\nwhen configured', 'S3 Object Lock\nwhen configured'] },
  ], 'Figure 7 — Defence in depth: each layer works even if the one above is bypassed.'),
  table([2800, 6226], ['OWASP LLM Top 10 risk', 'Controls'], [
    ['LLM01 Prompt injection', 'SEC-01/02 scanning, session and prompt notices, S-1 steering, GRD-10 on writes, Bedrock PROMPT_ATTACK filter (SEC-13)'],
    ['LLM02 Sensitive information disclosure', 'SEC-03, GRD-01 credential access blocks, audit redaction, prompts logged as hashes, Secrets Manager injection without printing'],
    ['LLM05 Improper output handling', 'SEC-09 diff, GRD-11, Informatica inject refusal, render value checks (SEC-08), test preflight'],
    ['LLM06 Excessive agency', 'Allow-lists, GRD-03/04/05/06/07/08, AWS read-only, test databases only, no superuser'],
  ]),
  gap(),
  table([1400, 1300, 6326], ['Exit code', 'From', 'Meaning'], [
    ['2', 'hook', 'preToolUse guard blocked the tool call; reason on stderr to the agent'],
    ['3', 'infa_sql_tool.py', 'refused by a security guardrail (XML, conversion, value, path)'],
    ['4', 'pgtest.sh', 'refused by the test preflight'],
    ['1', 'check / tests', 'a check or test failed'],
  ]),
  gap(),

  h1('8. Audit, correlation and lineage'),
  ...flow(['run_tests.sh / agentSpawn\nnew run id', 'MIGRATION_RUN_ID\n+ TRACEPARENT to children', 'tools + hooks\naudit records', 'PostgreSQL session\napplication_name mig:…:run8', 'OpenLineage event\nrun facet with run id'], PAL.data, 'Figure 8 — One W3C trace id links the Kiro session, tools, database sessions and lineage.'),
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
  ], 'Figure 9 — Each concern resolves independently; a missing or denied service never stops a migration in auto mode.'),
  table([2000, 3300, 3726], ['Concern', 'AWS API (read-only probe · write)', 'Limits and behaviour'], [
    ['audit', '`DescribeLogGroups` · `CreateLogStream`, `PutLogEvents`', 'stream per day/host; batches ≤ 1,048,576 bytes (26 bytes/event overhead), ≤ 10,000 events, ≤ 24 h, chronological; files > 14 days stay local; per-file offsets'],
    ['lineage', '`GetDomain` · `PostLineageEvent`', 'OpenLineage ≤ 300,000 bytes; client token = local document id; pending until sent'],
    ['guardrail', '`GetGuardrail` · `ApplyGuardrail` (source INPUT)', 'chunked, per-run character budget; matched sensitive values never stored'],
    ['archive', '`HeadBucket` · `PutObject`', 'SHA-256 checksum, SSE-KMS, Object Lock retention; local copy with manifest'],
    ['secrets', '`DescribeSecret` · `GetSecretValue`', 'PG* variables injected into a child process only'],
  ]),
  gap(),
  note('The kit calls the AWS CLI with timeouts and never creates AWS resources. Setup commands and the least-privilege IAM policy are in `references/aws-services.md`.'),

  h1('10. Test architecture'),
  ...layers([
    { label: 'Engine', fill: PAL.tool, boxes: ['preflight\nSEC-12', 'guard_and_reset\ntest DB · no superuser · run id', 'framework\nassert equal/true/raises/sqlstate', 'report\nsummary · exit code · results file'] },
    { label: 'Suites', fill: PAL.skill, boxes: ['project suites\n153', 'sql-conversion\n257 SQL', 'sql-reporting\n88 SQL', 'informatica\n38 SQL'] },
    { label: 'Unit / hooks', fill: PAL.kiro, boxes: ['migkit\n33 (stub AWS CLI)', 'infa_sql_tool\n27', 'agent hooks\n15'] },
    { label: 'Coverage gate', fill: PAL.data, boxes: ['H · P · CC', 'RQ · RP', 'IC', 'SEC · LOG · SVC', 'GRD · HOOK'] },
  ], 'Figure 10 — 611 checks; every catalog row marked auto must be covered by a tagged test.'),
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
    ['Local-only overrides', '`PGTEST_ALLOW_SUPERUSER=1`, `PGTEST_ALLOW_DANGEROUS=1` (blocked for the agent)'],
  ]),
  gap(),

  h1('12. Platforms and packaging'),
  table([2600, 3200, 3226], ['Concern', 'Linux / macOS', 'Windows'], [
    ['Scripts', '`*.sh` (bash)', '`*.ps1` (PowerShell 5.1+ / 7) with a `.cmd` launcher, same arguments; shared helpers in `winlib.ps1`'],
    ['Python', '`python3`', '`python` or `py -3`; `PYTHONUTF8=1`, hooks run `python -X utf8`'],
    ['Agent', '`sql-migration-agent`', '`sql-migration-agent-windows`, generated by `make_windows_agent.py`, checked for drift'],
    ['File locks', '`fcntl.flock`', '`msvcrt.locking` on a sidecar `.lock` file'],
    ['Text I/O', 'UTF-8, LF', 'UTF-8 forced (stdin, stdout, files); XML keeps its own encoding and CRLF'],
    ['Guard hook', 'bash forms of each rule', 'PowerShell and cmd.exe forms (`iwr | iex`, `Remove-Item -Recurse`, `$env:…=`, `aws.exe`, `psql.exe`), `\\` paths normalised'],
    ['Line endings', '`.gitattributes`: `.sh` LF', '`.cmd` / `.ps1` CRLF; XML and `.prm` never converted'],
  ]),
  gap(),
  p('**Packaging:** `package.sh` / `package.cmd` run `package.py`. It clears hidden flags on `.kiro` (the name itself is required by Kiro) and zips the workspace with `.kiro` first. Bytes, line endings and executable bits are kept, and the archive is verified to contain the steering files, every `SKILL.md`, both agents and the settings. Runtime `logs/` are excluded by default.'),
  p('**Parity test (HOOK-05):** every `.sh` must have a `.ps1` twin and a `.cmd` launcher with the right line endings and a UTF-8 BOM, and the Windows agent must match the generated one.'),

  h1('13. Roadmap'),
  table([1700, 7326], ['Stage', 'Skills'], [
    ['Delivered', 'SQL Server → Aurora PostgreSQL (T-SQL code and DDL) · reporting and analytics SQL · Informatica ETL with SQL Server SQL → PostgreSQL'],
    ['Next', 'Schema mismatch detection (source ↔ target tables, columns, types, nullability, keys, collation) · schema change tracking (DDL drift, affected objects and tests) · metadata and data validation (inventory, row counts, checksums, sample diffs)'],
    ['Later', 'SQL Server stored procedures → Oracle (PL/SQL) · SQL Server → Amazon Redshift · Informatica ETL → Oracle and Redshift'],
  ]),
  gap(),
  p('Each new target is a steering file, a skill with examples and a catalog, and tagged tests. They reuse the agent, the guardrail hooks, migkit (security, audit, lineage, AWS services), the test engine and the coverage gate.'),

  h1('14. Reuse and extension'),
  bullet('Copy the steering files and the skill folders; `sql-conversion` is required by the others (shared engine and migkit).'),
  bullet('Write a project-specific `project.md`; keep the other steering files generic.'),
  bullet('Add a skill: `SKILL.md` + references + a catalog with ids + tagged tests + `run_skill_tests.sh`, then register it in `supporting-files/run_tests.sh`.'),
  bullet('Add a guardrail: a GRD row in `GUARDRAILS.md`, the rule in `guard_tool.py`, and positive and negative tests.'),
  bullet('Add an AWS back end: a concern in `services.py` (probe, write, fallback), a SVC row and stub-CLI tests.'),

  h1('15. Open items'),
  p('Current open items (AWS access and resources, Aurora parameter group, business decisions on six flagged objects, Informatica follow-ups outside the XML, planned skills, Kiro CLI 3.0 hooks) are tracked in `README.md` section 14.'),
];
const doc = new Document({
  creator: 'SQLMigrationProject',
  title: 'SQL Server to Aurora PostgreSQL — Technical Architecture',
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
      children: [t('SQL Server → Aurora PostgreSQL · Technical Architecture', { size: 16, color: '808080' }),
                 new TextRun({ children: [new Tab(), 'Page '], font: FONT, size: 16, color: '808080' }),
                 new TextRun({ children: [PageNumber.CURRENT], font: FONT, size: 16, color: '808080' })] })] }) },
    children: body,
  }],
});

Packer.toBuffer(doc).then((buf) => { fs.writeFileSync(OUT, buf); console.log('wrote', OUT, buf.length, 'bytes'); });
