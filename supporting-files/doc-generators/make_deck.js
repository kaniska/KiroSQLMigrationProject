// Executive overview deck — SQL Server → Aurora PostgreSQL with Kiro.
// Every diagram is built from native PowerPoint shapes, text boxes and connectors (fully editable).
//   NODE_PATH=$(npm root -g) node make_deck.js ../Executive_Overview.pptx [slideNumber]
// With slideNumber only that slide is written (used for visual QA).
const pptxgen = require('pptxgenjs');

const OUT = process.argv[2] || 'Executive_Overview.pptx';
const ONLY = process.argv[3] ? parseInt(process.argv[3], 10) : null;

// ---------- palette & type ----------
const C = {
  ink: '0B2E3A',       // deep petrol (dominant)
  petrol: '124E5E',
  teal: '1F7A8C',
  mist: 'E8F1F3',      // light panels
  paper: 'FFFFFF',
  amber: 'F2A007',     // accent
  amberSoft: 'FDF1D6',
  text: '1E2B30',
  muted: '5B6B70',
  line: 'B9C8CC',
  sec: 'C0392B', secSoft: 'F9E0DD',
  aws: 'E8710A', awsSoft: 'FDE8D6',
  green: '2E7D4F', greenSoft: 'DFF0E5',
  violet: '5B4B8A', violetSoft: 'E9E4F5',
};
const HF = 'Cambria';
const BF = 'Calibri';
const W = 13.333, H = 7.5;

const pres = new pptxgen();
pres.layout = 'LAYOUT_WIDE';
pres.author = 'SQLMigrationProject';
pres.title = 'SQL Server to Aurora PostgreSQL, Amazon Redshift and Iceberg with Kiro — Executive Overview';

// ---------- helpers ----------
const shadow = () => ({ type: 'outer', color: '000000', blur: 6, offset: 2, angle: 90, opacity: 0.18 });

function title(slide, text, sub) {
  slide.addText(text, { x: 0.6, y: 0.35, w: W - 1.2, h: 0.75, fontFace: HF, fontSize: 32, bold: true, color: C.ink, margin: 0, isTextBox: true });
  if (sub) slide.addText(sub, { x: 0.6, y: 1.05, w: W - 1.2, h: 0.45, fontFace: BF, fontSize: 15, color: C.muted, margin: 0, isTextBox: true });
}

function box(slide, x, y, w, h, head, body, o = {}) {
  slide.addShape(pres.shapes.ROUNDED_RECTANGLE, {
    x, y, w, h, rectRadius: o.radius ?? 0.08,
    fill: { color: o.fill || C.mist }, line: { color: o.lineColor || o.fill || C.line, width: o.lineWidth ?? 0.75 },
    shadow: o.shadow ? shadow() : undefined,
  });
  const parts = [];
  if (head) parts.push({ text: head, options: { bold: true, fontSize: o.headSize || 14, color: o.headColor || C.ink, breakLine: !!body } });
  if (body) parts.push({ text: body, options: { fontSize: o.bodySize || 11, color: o.bodyColor || C.text } });
  slide.addText(parts, { x: x + 0.08, y: y + 0.04, w: w - 0.16, h: h - 0.08, fontFace: BF, align: o.align || 'center',
    valign: o.valign || 'middle', margin: 2, isTextBox: true, paraSpaceAfter: 2 });
}

function arrow(slide, x1, y1, x2, y2, o = {}) {
  slide.addShape(pres.shapes.LINE, {
    x: Math.min(x1, x2), y: Math.min(y1, y2), w: Math.max(Math.abs(x2 - x1), 0.001), h: Math.max(Math.abs(y2 - y1), 0.001),
    flipH: x2 < x1, flipV: y2 < y1,
    line: { color: o.color || C.muted, width: o.width || 1.5, endArrowType: o.noHead ? undefined : 'triangle', dashType: o.dash || 'solid' },
  });
}

function chip(slide, x, y, w, text, o = {}) {
  slide.addShape(pres.shapes.ROUNDED_RECTANGLE, { x, y, w, h: o.h || 0.34, rectRadius: 0.17, fill: { color: o.fill || C.amberSoft }, line: { color: o.fill || C.amberSoft } });
  slide.addText(text, { x, y, w, h: o.h || 0.34, fontFace: BF, fontSize: o.size || 11, bold: !!o.bold, color: o.color || C.ink, align: 'center', valign: 'middle', margin: 0, isTextBox: true });
}

function circleNum(slide, x, y, n, o = {}) {
  const d = o.d || 0.46;
  slide.addShape(pres.shapes.OVAL, { x, y, w: d, h: d, fill: { color: o.fill || C.amber }, line: { color: o.fill || C.amber } });
  slide.addText(String(n), { x, y, w: d, h: d, fontFace: HF, fontSize: o.size || 16, bold: true, color: o.color || C.ink, align: 'center', valign: 'middle', margin: 0, isTextBox: true });
}

function footer(slide, n) {
  slide.addText(`SQL Server → Aurora PostgreSQL with Kiro  ·  ${n}`, { x: 0.6, y: H - 0.42, w: 6, h: 0.3, fontFace: BF, fontSize: 9, color: C.muted, margin: 0, isTextBox: true });
}

// ---------- slides ----------
const slides = [];

// 1 — Title
slides.push((s) => {
  s.background = { color: C.ink };
  s.addText('SQL Server → Aurora PostgreSQL', { x: 0.8, y: 1.3, w: 11.5, h: 0.9, fontFace: HF, fontSize: 44, bold: true, color: C.paper, margin: 0, isTextBox: true });
  s.addText('Agentic migration with Kiro: guarded, tested, traceable', { x: 0.8, y: 2.2, w: 11.5, h: 0.6, fontFace: BF, fontSize: 22, color: 'CFE3E7', margin: 0, isTextBox: true });
  s.addText('Executive overview · steering · skills · architecture · MCP & knowledge · security guardrails · testing · AWS services', { x: 0.8, y: 2.85, w: 11.5, h: 0.4, fontFace: BF, fontSize: 13, color: '9FBFC6', italic: true, margin: 0, isTextBox: true });
  const stats = [['611', 'automated checks\npassing on Aurora PostgreSQL 17.7'], ['3', 'production skills\nT-SQL · reporting · Informatica ETL'], ['4', 'steering rulebooks\nalways in the agent\'s context'], ['0', 'failures in the latest\nfull verification run']];
  stats.forEach(([n, l], i) => {
    const x = 0.8 + i * 3.0;
    s.addShape(pres.shapes.ROUNDED_RECTANGLE, { x, y: 4.3, w: 2.7, h: 2.0, rectRadius: 0.1, fill: { color: C.petrol }, line: { color: C.petrol } });
    s.addText(n, { x, y: 4.4, w: 2.7, h: 1.0, fontFace: HF, fontSize: 48, bold: true, color: C.amber, align: 'center', margin: 0, isTextBox: true });
    s.addText(l, { x: x + 0.15, y: 5.4, w: 2.4, h: 0.8, fontFace: BF, fontSize: 12, color: 'E3EEF0', align: 'center', margin: 0, isTextBox: true });
  });
  s.addNotes('Purpose: a Kiro-based kit that migrates a SQL Server estate (database code, reports, Informatica ETL) to Aurora PostgreSQL. Every result is proven by tests; the agent operates inside deterministic guardrails with a full audit trail.');
});

// 2 — Why & what
slides.push((s, n) => {
  s.background = { color: C.paper };
  title(s, 'What the kit delivers', 'Three workstreams and three targets (Aurora · Redshift · Iceberg on S3), one method: convert faithfully, prove it, record everything');
  const cols = [
    ['Database code', 'T-SQL procedures, functions, triggers and DDL → PL/pgSQL', '19 routines + 17 tables converted\n6 business decisions flagged, none hidden', C.teal],
    ['Reports & analytics', 'Report and dashboard SQL on the converted schema', '15 tested report patterns\n24 query-correctness rules', C.violet],
    ['Informatica ETL', 'PowerCenter XML with embedded SQL Server SQL → PostgreSQL', '5 example mappings, 44 corner cases\nreal export format round-trips byte for byte', C.aws],
  ];
  cols.forEach(([h, d, r, col], i) => {
    const x = 0.6 + i * 4.1;
    s.addShape(pres.shapes.ROUNDED_RECTANGLE, { x, y: 1.8, w: 3.8, h: 3.6, rectRadius: 0.08, fill: { color: C.mist }, line: { color: C.mist }, shadow: shadow() });
    s.addShape(pres.shapes.OVAL, { x: x + 0.3, y: 2.05, w: 0.7, h: 0.7, fill: { color: col }, line: { color: col } });
    s.addText(String(i + 1), { x: x + 0.3, y: 2.05, w: 0.7, h: 0.7, fontFace: HF, fontSize: 22, bold: true, color: C.paper, align: 'center', valign: 'middle', margin: 0, isTextBox: true });
    s.addText(h, { x: x + 1.15, y: 2.05, w: 2.5, h: 0.7, fontFace: HF, fontSize: 20, bold: true, color: C.ink, valign: 'middle', margin: 0, isTextBox: true });
    s.addText(d, { x: x + 0.3, y: 2.95, w: 3.2, h: 0.9, fontFace: BF, fontSize: 14, color: C.text, margin: 0, isTextBox: true });
    s.addText(r, { x: x + 0.3, y: 4.0, w: 3.2, h: 1.1, fontFace: BF, fontSize: 13, bold: true, color: col, margin: 0, isTextBox: true });
  });
  const pr = ['Behaviour parity — bugs are preserved and flagged, never silently fixed', 'Done means tested — nothing is reported as converted without a passing run', 'Controls outside the model — hooks and tools enforce the rules deterministically'];
  pr.forEach((t, i) => {
    circleNum(s, 0.6, 5.6 + i * 0.46, '✓', { d: 0.34, size: 12, fill: C.amber });
    s.addText(t, { x: 1.1, y: 5.59 + i * 0.46, w: 11.5, h: 0.36, fontFace: BF, fontSize: 14, color: C.text, valign: 'middle', margin: 0, isTextBox: true });
  });
  footer(s, n);
});

// 3 — Productivity gain (hypothetical estate)
slides.push((s, n) => {
  s.background = { color: C.paper };
  title(s, 'Productivity gain — a worked example', 'Hypothetical estate: 200 stored procedures · 50 reports · 40 Informatica mappings (illustrative assumptions, replace with your baseline)');
  const hdr = (t) => ({ text: t, options: { bold: true, color: C.paper, fill: { color: C.ink }, fontSize: 11.5, align: 'center', valign: 'middle' } });
  const cellL = (t, o = {}) => ({ text: t, options: Object.assign({ fontSize: 11.5, color: C.text, valign: 'middle' }, o) });
  const cellR = (t, o = {}) => ({ text: t, options: Object.assign({ fontSize: 11.5, color: C.text, align: 'right', valign: 'middle' }, o) });
  const rows = [
    [hdr('Workstream'), hdr('Units'), hdr('Manual h / unit'), hdr('With kit h / unit'), hdr('Manual hours'), hdr('With kit hours'), hdr('Saved')],
    [cellL('Stored procedures → PL/pgSQL'), cellR('200'), cellR('15.0'), cellR('4.5'), cellR('3,000'), cellR('900'), cellR('2,100', { bold: true, color: C.green })],
    [cellL('Reports & analytics SQL'), cellR('50'), cellR('6.0'), cellR('2.0'), cellR('300'), cellR('100'), cellR('200', { bold: true, color: C.green })],
    [cellL('Informatica mappings'), cellR('40'), cellR('12.0'), cellR('3.5'), cellR('480'), cellR('140'), cellR('340', { bold: true, color: C.green })],
    [cellL('Total', { bold: true }), cellR('290', { bold: true }), cellR(''), cellR(''), cellR('3,780', { bold: true }), cellR('1,140', { bold: true }), cellR('2,640 (70%)', { bold: true, color: C.green })],
  ];
  s.addTable(rows, { x: 0.6, y: 1.75, w: 7.55, colW: [2.35, 0.65, 0.95, 0.95, 0.9, 0.9, 0.85], rowH: 0.42, fontFace: BF,
    border: { type: 'solid', pt: 0.75, color: C.line }, fill: { color: C.paper } });
  s.addText('Per unit, manual = analysis, conversion, writing tests, debugging. With kit = spec review, agent conversion with generated tests and checks, engineer review of flags and fixes.',
    { x: 0.6, y: 4.0, w: 7.55, h: 0.55, fontFace: BF, fontSize: 10.5, italic: true, color: C.muted, margin: 0, isTextBox: true });
  const beyond = [
    ['Quality', 'Tests and checks before delivery: assume 1 escaped defect per 4 objects manually (≈73) and 80% fewer with the kit (≈15); 6 h triage + fix each → ≈350 h less rework'],
    ['Future effort', 'Every object ships with tagged tests (611 checks today): regression per release drops from ≈80 h manual re-testing to a ≈10-minute run — ≈320 h per year at 4 releases'],
    ['Maintainability', 'A rule fixed once in steering or a skill is re-applied and re-verified everywhere; the coverage gate stops untested rules; the audit trail turns incident triage from hours into minutes'],
  ];
  beyond.forEach(([h, b], i) => {
    const y = 4.65 + i * 0.82;
    s.addShape(pres.shapes.ROUNDED_RECTANGLE, { x: 0.6, y, w: 7.55, h: 0.72, rectRadius: 0.05, fill: { color: C.mist }, line: { color: C.mist } });
    s.addText(h, { x: 0.75, y, w: 1.6, h: 0.72, fontFace: HF, fontSize: 13.5, bold: true, color: C.teal, valign: 'middle', margin: 0, isTextBox: true });
    s.addText(b, { x: 2.35, y, w: 5.7, h: 0.72, fontFace: BF, fontSize: 11, color: C.text, valign: 'middle', margin: 0, isTextBox: true });
  });
  const stats = [['2,640 h', 'development hours saved (70%)\n≈ 330 person-days'], ['≈350 h', 'less defect rework\n≈80% fewer escaped defects'], ['≈320 h / yr', 'regression effort avoided\nruns in minutes, not weeks'], ['100%', 'rules and corner cases\nunder automated tests']];
  stats.forEach(([big, small], i) => {
    const y = 1.75 + i * 1.32;
    s.addShape(pres.shapes.ROUNDED_RECTANGLE, { x: 8.55, y, w: 4.2, h: 1.18, rectRadius: 0.08, fill: { color: i === 0 ? C.ink : C.petrol }, line: { color: i === 0 ? C.ink : C.petrol }, shadow: shadow() });
    s.addText(big, { x: 8.7, y, w: 1.95, h: 1.18, fontFace: HF, fontSize: i === 2 ? 22 : 28, bold: true, color: C.amber, valign: 'middle', margin: 0, isTextBox: true });
    s.addText(small, { x: 10.65, y, w: 2.0, h: 1.18, fontFace: BF, fontSize: 11.5, color: 'E3EEF0', valign: 'middle', margin: 0, isTextBox: true });
  });
  footer(s, n);
  s.addNotes('All figures are a hypothetical example for discussion. Hours per unit: stored procedure manual 15 h (2 analysis, 6 conversion, 4 tests, 3 debugging) vs 4.5 h with the kit (1.5 spec and flag review, 2 review of generated code and tests, 1 fixes); report 6 h vs 2 h; Informatica mapping 12 h (finding SQL in XML, conversion, safe XML edits, testing) vs 3.5 h. Quality: 290 objects, 1 escaped defect per 4 objects manually (~73) vs 80% fewer (~15), 6 h each: 438 h vs 90 h. Regression: 2 engineers x 1 week = 80 h per release, 4 releases per year. Replace the assumptions with your own baseline.');
});

// 3 — Architecture
slides.push((s, n) => {
  s.background = { color: C.paper };
  title(s, 'Architecture at a glance', 'Kiro agent + steering + skills, deterministic tools, local-first evidence, optional AWS back ends');
  const L = 0.6, LW = 1.65, X0 = 2.45, RW = 10.3;
  const rows = [
    ['People', C.mist, ['Migration engineer\nKiro IDE · kiro-cli', 'Batch operator\nkiro_migrate.sh', 'Reviewer / security\ncatalogs · audit log']],
    ['Kiro agent', C.greenSoft, ['sql-migration-agent\nprompt · allow-lists · resources', 'Hooks — outside the model\nspawn · prompt · preToolUse guard · postToolUse · stop']],
    ['Knowledge', 'E3F1E0', ['Steering (always)\n4 rulebooks', 'Skills (on demand)\n3 skills · catalogs · examples', 'MCP (optional)\nPostgreSQL · SQL Server · AWS docs']],
    ['Tools', C.amberSoft, ['infa_sql_tool.py\nextract · check · inject · render', 'Test engine\npgtest.sh · coverage gate', 'migkit\nsecurity · audit · services']],
    ['Data', C.violetSoft, ['source/ → generated/\nT-SQL · XML · PL/pgSQL', 'Aurora PostgreSQL 17\ntest DB · IAM auth', 'logs/\naudit · lineage · archive']],
    ['AWS', C.awsSoft, ['CloudWatch Logs', 'DataZone', 'Bedrock Guardrails', 'S3 Object Lock', 'Secrets Manager']],
  ];
  const RH = 0.72, GAP = 0.2, Y0 = 1.65;
  rows.forEach(([lab, fill, items], r) => {
    const y = Y0 + r * (RH + GAP);
    box(s, L, y, LW, RH, lab, null, { fill: C.ink, headColor: C.paper, headSize: 13 });
    const gap = 0.15, w = (RW - gap * (items.length - 1)) / items.length;
    items.forEach((it, i) => {
      const [h, b] = it.split('\n');
      box(s, X0 + i * (w + gap), y, w, RH, h, b || null, { fill, lineColor: C.line, headSize: 12, bodySize: 10 });
    });
    if (r < rows.length - 1) arrow(s, X0 + RW / 2, y + RH, X0 + RW / 2, y + RH + GAP, { color: C.teal, width: 1.75 });
  });
  s.addText('Runs on Windows, Linux and macOS. AWS back ends are used when configured and reachable; otherwise the same data stays in logs/ and is synced later.', { x: X0, y: Y0 + 6 * (RH + GAP) - 0.12, w: RW, h: 0.3, fontFace: BF, fontSize: 10, italic: true, color: C.muted, margin: 0, isTextBox: true });
  s.addNotes('Read top to bottom: people use the Kiro agent; the agent draws on steering, skills and optional MCP servers; tools do everything that must be exact; data and evidence stay local unless AWS services are configured.');
});

// 4 — Steering
slides.push((s, n) => {
  s.background = { color: C.paper };
  title(s, 'Steering: what "correct" means', 'Always-loaded rulebooks — generic and portable except the project file');
  const cards = [
    ['migration.md', '17 hard rules [H] · 11 parity rules [P]', 'Type and syntax maps, transactions, errors, naming, validation checklist', C.teal],
    ['informatica-etl.md', '13 rules [IE]', 'Where SQL lives in PowerCenter XML, invariants ($$params, ?ports?, :TU.), datatype and connection mapping, real export format', C.aws],
    ['security.md', '11 rules [S]', 'Untrusted content, no secrets, least privilege, AWS read-only, one run id, logs are evidence', C.sec],
    ['project.md', 'project values', 'Aurora cluster and test database, folders, commands, AWS service status', C.violet],
  ];
  cards.forEach(([h, tag, d, col], i) => {
    const x = 0.6 + (i % 2) * 6.15, y = 1.75 + Math.floor(i / 2) * 2.35;
    s.addShape(pres.shapes.ROUNDED_RECTANGLE, { x, y, w: 5.95, h: 2.1, rectRadius: 0.08, fill: { color: C.mist }, line: { color: C.mist }, shadow: shadow() });
    s.addShape(pres.shapes.OVAL, { x: x + 0.3, y: y + 0.3, w: 0.55, h: 0.55, fill: { color: col }, line: { color: col } });
    s.addText('§', { x: x + 0.3, y: y + 0.3, w: 0.55, h: 0.55, fontFace: HF, fontSize: 18, bold: true, color: C.paper, align: 'center', valign: 'middle', margin: 0, isTextBox: true });
    s.addText(h, { x: x + 1.05, y: y + 0.25, w: 3.0, h: 0.4, fontFace: HF, fontSize: 19, bold: true, color: C.ink, margin: 0, isTextBox: true });
    chip(s, x + 1.05, y + 0.68, 2.9, tag, { fill: C.amberSoft, size: 11, bold: true });
    s.addText(d, { x: x + 0.3, y: y + 1.12, w: 5.4, h: 0.85, fontFace: BF, fontSize: 13, color: C.text, margin: 0, isTextBox: true });
  });
  s.addText('Steering tells the model what to do; hooks, tools and the test engine check the critical rules again without relying on the model.', { x: 0.6, y: 6.55, w: 12, h: 0.4, fontFace: BF, fontSize: 13, italic: true, color: C.petrol, margin: 0, isTextBox: true });
  footer(s, n);
});

// 5 — Skills
slides.push((s, n) => {
  s.background = { color: C.paper };
  title(s, 'Skills: how one unit of work is done and proven', 'Each skill = numbered procedure + worked examples + corner-case catalog + scripts + self-test');
  const sk = [
    ['sql-conversion', 'T-SQL → PL/pgSQL', [['10', 'procedure steps'], ['17', 'worked examples'], ['87', 'corner cases CC']], 'shared test engine · migkit · 290 tests', C.teal],
    ['sql-reporting', 'Report & analytics SQL', [['7', 'procedure steps'], ['15', 'report patterns RP'], ['24', 'query rules RQ']], 'tested report functions · 88 tests', C.violet],
    ['informatica-etl-conversion', 'PowerCenter XML', [['6', 'procedure steps'], ['5', 'example mappings'], ['44', 'corner cases IC']], 'infa_sql_tool.py · public corpus · 65 tests', C.aws],
  ];
  sk.forEach(([name, what, stats, foot, col], i) => {
    const x = 0.6 + i * 4.1, y = 1.75;
    s.addShape(pres.shapes.ROUNDED_RECTANGLE, { x, y, w: 3.85, h: 4.5, rectRadius: 0.08, fill: { color: C.paper }, line: { color: C.line, width: 1 }, shadow: shadow() });
    s.addShape(pres.shapes.ROUNDED_RECTANGLE, { x: x + 0.2, y: y + 0.2, w: 3.45, h: 0.95, rectRadius: 0.06, fill: { color: col }, line: { color: col } });
    s.addText([{ text: name, options: { bold: true, fontSize: 16, color: C.paper, breakLine: true } }, { text: what, options: { fontSize: 12, color: 'F4F4F4' } }],
      { x: x + 0.3, y: y + 0.22, w: 3.25, h: 0.9, fontFace: BF, valign: 'middle', margin: 0, isTextBox: true });
    stats.forEach(([num, lab], j) => {
      const yy = y + 1.35 + j * 0.85;
      s.addText(num, { x: x + 0.25, y: yy, w: 1.1, h: 0.7, fontFace: HF, fontSize: 30, bold: true, color: col, align: 'right', valign: 'middle', margin: 0, isTextBox: true });
      s.addText(lab, { x: x + 1.5, y: yy, w: 2.2, h: 0.7, fontFace: BF, fontSize: 14, color: C.text, valign: 'middle', margin: 0, isTextBox: true });
    });
    s.addText(foot, { x: x + 0.25, y: y + 3.95, w: 3.35, h: 0.4, fontFace: BF, fontSize: 11, italic: true, color: C.muted, margin: 0, isTextBox: true });
  });
  ['migration-assessment · MA-12', 'sql-conversion-redshift · RS-52', 'sql-conversion-iceberg · IB-51', 'schema-conformance · SC-22', 'schema-change-propagation · CP-20'].forEach((t, i) =>
    chip(s, 0.6 + i * 2.45, 6.45, 2.35, t, { fill: C.petrol, color: C.paper, size: 10.5, h: 0.34 }));
  s.addText('+ five skills (Sept 2026) on the same engine: assessment, Redshift, Iceberg on S3, schema conformance, change propagation. Kiro loads a skill when the request matches its description, or on /skill-name.', { x: 0.6, y: 6.85, w: 12.1, h: 0.3, fontFace: BF, fontSize: 10.5, color: C.muted, valign: 'middle', margin: 0, isTextBox: true });
  footer(s, n);
});

// 6 — Agent workflow with hooks
slides.push((s, n) => {
  s.background = { color: C.paper };
  title(s, 'How the agents work a request', 'Two agents — conversion and reporting — same method: the model writes; tools, tests and hooks decide what is allowed and what counts as done');
  const steps = [['Request', '"Convert source/usp_X.sql"'], ['Scan input', 'injection · secrets · hidden text'], ['Convert', 'steering + skill + examples'], ['Check', 'no new capability · invariants'], ['Test', 'Aurora test DB · coverage gate'], ['Report', 'flags · findings · run id']];
  const bw = 1.85, gap = 0.22, y = 1.95;
  steps.forEach(([h, b], i) => {
    const x = 0.6 + i * (bw + gap);
    box(s, x, y, bw, 1.25, h, b, { fill: i === 4 ? C.greenSoft : C.mist, headSize: 15, bodySize: 11, shadow: true });
    if (i < steps.length - 1) arrow(s, x + bw + 0.02, y + 0.62, x + bw + gap - 0.02, y + 0.62, { color: C.teal, width: 2 });
  });
  s.addShape(pres.shapes.ROUNDED_RECTANGLE, { x: 0.6, y: 3.75, w: 12.1, h: 2.55, rectRadius: 0.06, fill: { color: C.ink }, line: { color: C.ink } });
  s.addText('Kiro hooks — run outside the model on every session, prompt and tool call', { x: 0.85, y: 3.85, w: 11.6, h: 0.45, fontFace: HF, fontSize: 16, bold: true, color: C.paper, margin: 0, isTextBox: true });
  const hooks = [['agentSpawn', 'new run id · security notice · migration status'], ['userPromptSubmit', 'prompt hash only · injection warning'], ['preToolUse', 'guard: allow or BLOCKED GRD-nn'], ['postToolUse', 'redacted tool audit'], ['stop', 'session record · sync evidence']];
  hooks.forEach(([h, b], i) => {
    const x = 0.85 + i * 2.37;
    box(s, x, 4.45, 2.2, 1.6, h, b, { fill: i === 2 ? C.amber : C.petrol, headColor: i === 2 ? C.ink : C.paper, bodyColor: i === 2 ? C.ink : 'DCEBEE', headSize: 14, bodySize: 11 });
  });
  arrow(s, 7.0, 3.2, 7.0, 3.75, { color: C.amber, width: 2, dash: 'dash' });
  s.addText('every tool call', { x: 7.1, y: 3.3, w: 2, h: 0.35, fontFace: BF, fontSize: 11, italic: true, color: C.muted, margin: 0, isTextBox: true });
  footer(s, n);
});

// 7 — Knowledge bases & MCP
slides.push((s, n) => {
  s.background = { color: C.paper };
  title(s, 'Knowledge bases and MCP servers', 'Curated knowledge in the workspace; live facts through read-only MCP servers — all results treated as data');
  // centre
  box(s, 5.15, 3.05, 3.05, 1.5, 'sql-migration-agent', 'Kiro IDE / kiro-cli', { fill: C.ink, headColor: C.paper, bodyColor: 'CFE3E7', headSize: 17, bodySize: 12, shadow: true });
  box(s, 5.4, 5.25, 2.55, 0.85, 'preToolUse guard', 'critical SQL · write mode blocked', { fill: C.amber, headSize: 13, bodySize: 10 });
  arrow(s, 6.67, 4.55, 6.67, 5.25, { color: C.amber, width: 1.75 });
  // left: knowledge
  s.addText('Knowledge bases (in the workspace)', { x: 0.6, y: 1.7, w: 4.2, h: 0.4, fontFace: HF, fontSize: 15, bold: true, color: C.teal, margin: 0, isTextBox: true });
  const kb = [['Steering rulebooks', 'always loaded'], ['Skill procedures', 'loaded on demand'], ['Catalogs', 'CC · IC · RQ/RP · SEC/LOG/SVC · GRD'], ['Worked examples', '17 T-SQL · 15 reports · 5 mappings'], ['Public export corpus', 'real PowerCenter XML (HHS)']];
  kb.forEach(([h, b], i) => {
    const y = 2.2 + i * 0.88;
    box(s, 0.6, y, 3.9, 0.74, h, b, { fill: 'E3F1E0', headSize: 13, bodySize: 10, align: 'left' });
    arrow(s, 4.5, y + 0.37, 5.15, 3.8, { color: C.green, width: 1 });
  });
  // right: MCP
  s.addText('MCP servers (optional, disabled by default)', { x: 8.75, y: 1.7, w: 4.2, h: 0.4, fontFace: HF, fontSize: 15, bold: true, color: C.aws, margin: 0, isTextBox: true });
  const mcp = [['PostgreSQL MCP', 'table schema · read-only query'], ['SQL Server MCP', 'source procedure text'], ['AWS Knowledge MCP', 'Aurora features · regions'], ['AWS Documentation MCP', 'search · read'], ['AWS API MCP', 'READ_OPERATIONS_ONLY']];
  mcp.forEach(([h, b], i) => {
    const y = 2.2 + i * 0.88;
    box(s, 8.85, y, 3.9, 0.74, h, b, { fill: C.awsSoft, headSize: 13, bodySize: 10, align: 'left' });
    arrow(s, 8.2, 3.8, 8.85, y + 0.37, { color: C.aws, width: 1 });
  });
  s.addText('Test suites always run through the shell (psql meta-commands); MCP is for facts, not for proof.', { x: 0.6, y: 6.6, w: 12.1, h: 0.35, fontFace: BF, fontSize: 12, italic: true, color: C.muted, margin: 0, isTextBox: true });
  footer(s, n);
});

// 8 — Informatica pipeline
slides.push((s, n) => {
  s.background = { color: C.paper };
  title(s, 'Informatica ETL: exact where it must be exact', 'The tool handles XML, encodings, integrity and lineage; the model converts only the SQL');
  const st = [['extract', 'safe XML parse\nscan · manifest'], ['convert', 'SQL Server SQL →\nPostgreSQL files'], ['check', 'Informatica invariants\nleftover T-SQL · SEC'], ['inject', 'converted XML\nintegrity · lineage'], ['render', 'real .prm values\nsafe parameters'], ['test', 'Aurora test DB\nside effects verified']];
  const bw = 1.85, gap = 0.2, y = 1.85;
  st.forEach(([h, b], i) => {
    const x = 0.6 + i * (bw + gap);
    circleNum(s, x + bw / 2 - 0.23, y, i + 1);
    box(s, x, y + 0.6, bw, 1.35, h, b, { fill: C.awsSoft, headSize: 16, bodySize: 11, shadow: true });
    if (i < st.length - 1) arrow(s, x + bw + 0.02, y + 1.27, x + bw + gap - 0.02, y + 1.27, { color: C.aws, width: 2 });
  });
  const facts = [
    ['Real export format', 'Windows-1252 / ISO-8859-1, CRLF, NAME ="…" spacing — unchanged exports round-trip byte for byte (14 public exports verified)'],
    ['Full SQL Server jobs', 'CTEs, window functions, OUTER APPLY, lookup and update overrides, Pre/Post SQL batches (SET NOCOUNT, IF OBJECT_ID, EXEC)'],
    ['Integrity', 'Only SQL values change; export hash checked; CRCVALUE-protected elements never modified'],
    ['Lineage', 'OpenLineage event per conversion: source/target tables, SHA-256 of every SQL value, run id'],
  ];
  facts.forEach(([h, b], i) => {
    const x = 0.6 + (i % 2) * 6.15, yy = 4.25 + Math.floor(i / 2) * 1.2;
    s.addShape(pres.shapes.ROUNDED_RECTANGLE, { x, y: yy, w: 5.95, h: 1.05, rectRadius: 0.06, fill: { color: C.mist }, line: { color: C.mist } });
    s.addText([{ text: h, options: { bold: true, fontSize: 14, color: C.ink, breakLine: true } }, { text: b, options: { fontSize: 12, color: C.text } }],
      { x: x + 0.2, y: yy + 0.05, w: 5.55, h: 0.95, fontFace: BF, valign: 'middle', margin: 0, isTextBox: true });
  });
  footer(s, n);
});

// 9 — Security guardrails
slides.push((s, n) => {
  s.background = { color: C.paper };
  title(s, 'Security guardrails: defence in depth', 'Inputs are untrusted; each layer holds even if the one above is bypassed');
  const layers = [
    ['1  Input', 'Scanner: prompt injection · hidden Unicode · secrets · dangerous SQL', 'Safe XML: no entities, DTD subsets or remote DTDs'],
    ['2  Agent', 'Allow-lists for commands and write paths', 'Guard hook GRD-01..11 blocks credentials, exfiltration, tampering, AWS changes'],
    ['3  Tools', 'Conversion may not add capabilities (COPY PROGRAM, dblink, ALTER SYSTEM…)', 'Safe parameter values · paths inside the folder · XML integrity'],
    ['4  Database', 'Test preflight blocks shell escapes and secrets in test files', 'Test databases only · no superuser · 15-minute IAM tokens'],
    ['5  Evidence', 'Redacted, hash-chained audit log · prompts stored as hashes', 'Bedrock Guardrails and S3 Object Lock when configured'],
  ];
  layers.forEach(([h, a, b], i) => {
    const y = 1.7 + i * 0.93, w = 8.1 - i * 0.35, x = 0.6 + i * 0.175;
    s.addShape(pres.shapes.ROUNDED_RECTANGLE, { x, y, w, h: 0.8, rectRadius: 0.06, fill: { color: i === 4 ? C.violetSoft : C.secSoft }, line: { color: i === 4 ? C.violetSoft : C.secSoft } });
    s.addText(h, { x: x + 0.15, y, w: 1.35, h: 0.8, fontFace: HF, fontSize: 14, bold: true, color: i === 4 ? C.violet : C.sec, valign: 'middle', margin: 0, isTextBox: true });
    s.addText([{ text: a, options: { fontSize: 11.5, color: C.text, breakLine: true } }, { text: b, options: { fontSize: 11.5, color: C.text } }],
      { x: x + 1.5, y, w: w - 1.65, h: 0.8, fontFace: BF, valign: 'middle', margin: 0, isTextBox: true });
  });
  // OWASP map
  s.addShape(pres.shapes.ROUNDED_RECTANGLE, { x: 9.0, y: 1.7, w: 3.75, h: 4.55, rectRadius: 0.06, fill: { color: C.ink }, line: { color: C.ink } });
  s.addText('OWASP LLM Top 10', { x: 9.2, y: 1.8, w: 3.4, h: 0.45, fontFace: HF, fontSize: 16, bold: true, color: C.amber, margin: 0, isTextBox: true });
  const ow = [['LLM01 Prompt injection', 'scanning · notices · guard · Bedrock filter'], ['LLM02 Sensitive info', 'credential blocks · redaction · Secrets Manager'], ['LLM05 Output handling', 'conversion diff · preflight · safe values'], ['LLM06 Excessive agency', 'allow-lists · AWS read-only · test DB only']];
  ow.forEach(([h, b], i) => {
    s.addText([{ text: h, options: { bold: true, fontSize: 12.5, color: C.paper, breakLine: true } }, { text: b, options: { fontSize: 11, color: 'CFE3E7' } }],
      { x: 9.2, y: 2.35 + i * 0.95, w: 3.4, h: 0.85, fontFace: BF, valign: 'top', margin: 0, isTextBox: true });
  });
  const exits = [['exit 2', 'hook blocked'], ['exit 3', 'tool refused'], ['exit 4', 'test preflight refused']];
  exits.forEach(([a, b], i) => chip(s, 0.6 + i * 2.75, 6.5, 2.55, `${a} · ${b}`, { fill: C.secSoft, color: C.sec, bold: true, size: 11 }));
  footer(s, n);
});

// 10 — Audit & lineage
slides.push((s, n) => {
  s.background = { color: C.paper };
  title(s, 'Audit, correlation and lineage', 'One run id connects the Kiro session, every tool, every database session and every lineage record');
  const t = [['Run starts', 'agentSpawn or run_tests.sh\ncreates the run id'], ['Tools inherit', 'MIGRATION_RUN_ID\n+ W3C traceparent'], ['Audit records', 'JSON · UTC ms timestamps\nhash-chained'], ['Database sessions', 'application_name\nmig:<manifest>:<run8>'], ['Lineage', 'OpenLineage event\nwith SHA-256 hashes']];
  s.addShape(pres.shapes.LINE, { x: 1.2, y: 2.62, w: 10.9, h: 0, line: { color: C.teal, width: 3 } });
  t.forEach(([h, b], i) => {
    const x = 0.6 + i * 2.5;
    s.addShape(pres.shapes.OVAL, { x: x + 0.93, y: 2.4, w: 0.44, h: 0.44, fill: { color: C.amber }, line: { color: C.paper, width: 2 } });
    box(s, x, 3.05, 2.3, 1.25, h, b, { fill: C.mist, headSize: 14, bodySize: 11, shadow: true });
  });
  s.addText('Every audit record carries', { x: 0.6, y: 4.65, w: 6, h: 0.4, fontFace: HF, fontSize: 15, bold: true, color: C.ink, margin: 0, isTextBox: true });
  const fields = ['timestamp (UTC, ms)', 'severity', 'event', 'run_id = trace_id', 'span / parent span', 'service · host · user', 'redacted attributes', 'seq · prev_hash · hash'];
  fields.forEach((f, i) => chip(s, 0.6 + (i % 4) * 3.05, 5.15 + Math.floor(i / 4) * 0.5, 2.85, f, { fill: C.mist, size: 12 }));
  box(s, 0.6, 6.2, 12.1, 0.55, null, null, { fill: C.ink });
  s.addText([{ text: 'Troubleshoot:  ', options: { bold: true, color: C.amber } }, { text: 'audit.py tail --run <run8>   ·   audit.py verify (tamper check)   ·   services.py status', options: { color: C.paper, fontFace: 'Courier New' } }],
    { x: 0.8, y: 6.2, w: 11.7, h: 0.55, fontFace: BF, fontSize: 13, valign: 'middle', margin: 0, isTextBox: true });
  footer(s, n);
});

// 11 — AWS services
slides.push((s, n) => {
  s.background = { color: C.paper };
  title(s, 'AWS service interaction — with local fallback', 'Each concern resolves on its own: AWS when configured and reachable, the local store otherwise');
  box(s, 0.6, 2.0, 2.6, 3.75, 'Kit components', 'infa_sql_tool.py\npgtest.sh · run_tests.sh\nKiro hooks\nkiro_migrate.sh', { fill: C.mist, headSize: 15, bodySize: 12, shadow: true });
  box(s, 3.85, 2.95, 2.5, 2.0, 'migkit services', 'resolve per concern\nauto · aws · local\nprobe cached', { fill: C.ink, headColor: C.paper, bodyColor: 'CFE3E7', headSize: 15, bodySize: 12, shadow: true });
  arrow(s, 3.2, 3.95, 3.85, 3.95, { color: C.teal, width: 2 });
  const svc = [['audit', 'Amazon CloudWatch Logs', 'logs/audit/*.jsonl'], ['lineage', 'Amazon DataZone', 'logs/state/lineage.jsonl'], ['guardrail', 'Amazon Bedrock Guardrails', 'built-in scanner (always)'], ['archive', 'Amazon S3 + Object Lock', 'logs/archive/'], ['secrets', 'AWS Secrets Manager', 'IAM token / environment']];
  s.addText('AWS (when configured)', { x: 7.2, y: 1.6, w: 2.8, h: 0.35, fontFace: HF, fontSize: 13, bold: true, color: C.aws, margin: 0, isTextBox: true });
  s.addText('Local fallback', { x: 10.35, y: 1.6, w: 2.4, h: 0.35, fontFace: HF, fontSize: 13, bold: true, color: C.teal, margin: 0, isTextBox: true });
  svc.forEach(([c, a, l], i) => {
    const y = 2.0 + i * 0.77;
    box(s, 7.2, y, 2.85, 0.62, a, c, { fill: C.awsSoft, headSize: 12, bodySize: 10 });
    box(s, 10.35, y, 2.4, 0.62, l, null, { fill: 'E3F1E0', headSize: 11 });
    arrow(s, 6.35, 3.95, 7.2, y + 0.32, { color: C.aws, width: 1.25 });
    arrow(s, 10.05, y + 0.31, 10.35, y + 0.31, { color: C.teal, width: 1.25, dash: 'dash' });
  });
  footer(s, n);
  const notes = ['Nothing is created automatically — setup commands and a least-privilege IAM policy are provided', 'Fallback is logged (services.fallback) and records sync when AWS becomes available', 'Limits handled: CloudWatch batch size and age, DataZone event size, guardrail budget'];
  notes.forEach((t, i) => {
    circleNum(s, 0.6, 5.97 + i * 0.36, '•', { d: 0.24, size: 10, fill: C.amber });
    s.addText(t, { x: 1.0, y: 5.92 + i * 0.36, w: 11.7, h: 0.34, fontFace: BF, fontSize: 12, color: C.text, valign: 'middle', margin: 0, isTextBox: true });
  });
});

// 12 — Tests: numbers
slides.push((s, n) => {
  s.background = { color: C.paper };
  title(s, 'Proof: 693 automated checks, one gate', 'Latest full run on Aurora PostgreSQL 17.7 — 0 failures, every catalog rule covered');
  s.addChart(pres.charts.BAR, [{ name: 'Checks', labels: ['Project suites', 'sql-conversion (SQL)', 'sql-reporting (SQL + dialects)', 'Informatica (SQL)', 'migkit + governance (unit)', 'Informatica tool (unit)', 'Assessment · Redshift · Iceberg · schema · change (unit)', 'Hooks · agents · MCP'], values: [153, 257, 93, 38, 41, 29, 52, 30] }], {
    x: 0.6, y: 1.65, w: 7.3, h: 5.1, barDir: 'bar', chartColors: [C.teal], showValue: true, dataLabelPosition: 'outEnd', dataLabelColor: C.ink, dataLabelFontSize: 12,
    catAxisLabelColor: C.text, catAxisLabelFontSize: 12, valAxisLabelColor: C.muted, valAxisLabelFontSize: 10, valGridLine: { color: 'E3E8EA', size: 0.5 }, catGridLine: { style: 'none' },
    showLegend: false, showTitle: true, title: 'Automated checks by layer', titleFontSize: 14, titleColor: C.ink, catAxisOrientation: 'maxMin',
  });
  const cov = [['H · P · CC', '27 rules · 86 corner cases'], ['RQ · RP · IC', '23 rules · 15 patterns · 42 cases'], ['SEC · LOG · SVC · GOV', '13 · 8 · 11 · 12 controls'], ['MA · RS · IB · SC · CP', '12 · 52 · 51 · 22 · 20 rules'], ['GRD · HOOK · AG · MCP', '12 guardrails · 5 hooks · 8 agent rules · 4 MCP rules']];
  s.addText('Coverage gate: no rule without a test', { x: 8.3, y: 1.8, w: 4.45, h: 0.45, fontFace: HF, fontSize: 15, bold: true, color: C.ink, margin: 0, isTextBox: true });
  cov.forEach(([h, b], i) => {
    const y = 2.4 + i * 0.85;
    s.addShape(pres.shapes.ROUNDED_RECTANGLE, { x: 8.3, y, w: 4.45, h: 0.72, rectRadius: 0.06, fill: { color: C.greenSoft }, line: { color: C.greenSoft } });
    s.addText('100%', { x: 8.4, y, w: 1.1, h: 0.72, fontFace: HF, fontSize: 18, bold: true, color: C.green, valign: 'middle', margin: 0, isTextBox: true });
    s.addText([{ text: h, options: { bold: true, fontSize: 13, color: C.ink, breakLine: true } }, { text: b, options: { fontSize: 11, color: C.text } }],
      { x: 9.55, y, w: 3.1, h: 0.72, fontFace: BF, valign: 'middle', margin: 0, isTextBox: true });
  });
  footer(s, n);
  s.addText('Manual-only by nature: CC-67, RQ-20, IC-31, IC-34', { x: 8.3, y: 6.72, w: 4.45, h: 0.3, fontFace: BF, fontSize: 10, italic: true, color: C.muted, margin: 0, isTextBox: true });
});

// 13 — Test types
slides.push((s, n) => {
  s.background = { color: C.paper };
  title(s, 'Different kinds of tests, each answering a different risk', 'From "does it behave the same" to "can it be tricked" to "can we prove what happened"');
  const types = [
    ['Behaviour parity', 'converted routines return the same results — including preserved bugs', C.teal],
    ['Worked examples', 'every template in every skill runs on PostgreSQL', C.teal],
    ['Corner cases', 'tagged tests for each risky construct (CC, IC)', C.teal],
    ['Report correctness', 'hand-computed numbers per pattern and rule', C.violet],
    ['Static checks', 'leftover T-SQL, duplicates, volatility, COMMIT in functions', C.violet],
    ['Round trip & regeneration', 'converted XML reproducible; real exports byte for byte', C.aws],
    ['Security negative tests', 'XXE, billion laughs, injection, secrets, dangerous conversions, traversal', C.sec],
    ['Guardrail hook tests', 'each GRD rule blocks its cases and allows the normal workflow', C.sec],
    ['Audit & lineage tests', 'format, correlation, redaction, hash chain, concurrency', C.green],
    ['AWS service tests', 'stub AWS CLI: fallback, fail-loud, batching, idempotency, Object Lock', C.aws],
    ['Engine correlation', 'run id and application_name visible in PostgreSQL', C.green],
    ['Coverage enforcement', 'the run fails if any catalog rule has no test', C.ink],
  ];
  types.forEach(([h, b, col], i) => {
    const x = 0.6 + (i % 4) * 3.05, y = 1.7 + Math.floor(i / 4) * 1.68;
    s.addShape(pres.shapes.ROUNDED_RECTANGLE, { x, y, w: 2.85, h: 1.5, rectRadius: 0.06, fill: { color: C.mist }, line: { color: C.mist }, shadow: shadow() });
    s.addShape(pres.shapes.OVAL, { x: x + 0.18, y: y + 0.2, w: 0.32, h: 0.32, fill: { color: col }, line: { color: col } });
    s.addText(h, { x: x + 0.6, y: y + 0.12, w: 2.15, h: 0.48, fontFace: BF, fontSize: 14, bold: true, color: C.ink, valign: 'middle', margin: 0, isTextBox: true });
    s.addText(b, { x: x + 0.18, y: y + 0.65, w: 2.55, h: 0.78, fontFace: BF, fontSize: 11.5, color: C.text, margin: 0, isTextBox: true });
  });
  footer(s, n);
});

// Roadmap — future skills
slides.push((s, n) => {
  s.background = { color: C.paper };
  title(s, 'Roadmap: from one migration path to a migration platform', 'Every new skill reuses the same agent, guardrails, audit, test engine and coverage gate');
  const cols = [
    ['Delivered', C.green, C.greenSoft, [
      ['SQL Server → Aurora PostgreSQL · reports · Informatica', 'procedures, functions, triggers, DDL · 15 report patterns · PowerCenter XML'],
      ['Assessment + Redshift + Iceberg on S3', 'placement (M2RVE), warehouse DDL/views/procedures, lake tables, Athena views, Glue jobs'],
      ['Schema conformance + change propagation', 'hashed snapshots, per-column classification, cast-before-rename dry-run packages'],
    ]],
    ['Next', C.teal, C.mist, [
      ['Data validation at a snapshot', 'row counts, key sets, checksums, sample diffs on all targets (V-012…V-021 executed)'],
      ['Serving paths', 'Redshift Spectrum / managed Iceberg tables; Glue Data Catalog multi-dialect views'],
      ['MCP + AI-DLC (placeholders started)', 'kit MCP server serves the read-only tools today; gates and packages mapped to AI-DLC phases next'],
    ]],
    ['Later', C.violet, C.violetSoft, [
      ['SQL Server stored procedures → Oracle', 'T-SQL → PL/SQL, packages, sequences, exceptions'],
      ['Informatica ETL → Redshift and Oracle', 'overrides and Pre/Post SQL per target; COPY / UNLOAD'],
      ['Live evidence on Redshift / Athena', 'once test workgroups and databases exist (never created by the kit)'],
    ]],
  ];
  cols.forEach(([h, col, soft, items], i) => {
    const x = 0.6 + i * 4.1;
    s.addShape(pres.shapes.CHEVRON, { x, y: 1.7, w: 3.9, h: 0.62, fill: { color: col }, line: { color: col } });
    s.addText(h, { x: x + 0.3, y: 1.7, w: 3.3, h: 0.62, fontFace: HF, fontSize: 18, bold: true, color: C.paper, align: 'center', valign: 'middle', margin: 0, isTextBox: true });
    items.forEach(([t, d], j) => {
      const y = 2.55 + j * 1.12;
      s.addShape(pres.shapes.ROUNDED_RECTANGLE, { x, y, w: 3.85, h: 0.98, rectRadius: 0.06, fill: { color: soft }, line: { color: soft }, shadow: shadow() });
      s.addText([{ text: t, options: { bold: true, fontSize: 13, color: C.ink, breakLine: true } }, { text: d, options: { fontSize: 11, color: C.text } }],
        { x: x + 0.18, y, w: 3.5, h: 0.98, fontFace: BF, valign: 'middle', margin: 0, isTextBox: true });
    });
  });
  s.addShape(pres.shapes.ROUNDED_RECTANGLE, { x: 0.6, y: 5.95, w: 12.1, h: 0.95, rectRadius: 0.06, fill: { color: C.ink }, line: { color: C.ink } });
  s.addText('Reused by every new skill', { x: 0.8, y: 5.95, w: 2.6, h: 0.95, fontFace: HF, fontSize: 14, bold: true, color: C.amber, valign: 'middle', margin: 0, isTextBox: true });
  const reuse = ['guardrail hooks', 'migkit: security · audit · lineage · AWS services', 'test engine + coverage gate', 'steering + skill + examples pattern', 'Windows · Linux · macOS scripts'];
  reuse.forEach((r, i) => chip(s, 3.45 + (i % 3) * 3.1, 6.07 + Math.floor(i / 3) * 0.4, 2.95, r, { fill: C.petrol, color: C.paper, size: 10.5, h: 0.32 }));
  footer(s, n);
  s.addNotes('Delivered in September 2026: five new skills (assessment, Redshift, Iceberg, schema conformance, change propagation) and a governance layer shared by all eight. Next: data validation proves the data, not only the code; serving paths for BI. AI-DLC: the kit already produces reviewable packages per unit of work; integrating with the AI-Driven Development Lifecycle is planned as steering plus an adapter, no code yet. Later: Oracle targets and Informatica ETL to Redshift/Oracle on the same engine and guardrails.');
});

// 14 — Open items / roadmap
slides.push((s, n) => {
  s.background = { color: C.paper };
  title(s, 'Open items and next steps', 'Nothing here blocks the tests today; each item has documented commands in the README');
  const cols = [
    ['Access & AWS', C.aws, ['Replace root access keys with an IAM Identity Center user or role', 'Create KMS key, CloudWatch Logs group, Bedrock guardrail, S3 Object Lock bucket, DataZone domain', 'Fill migration-services.json and sync collected evidence']],
    ['Database & code', C.teal, ['Aurora custom parameter group: pgaudit, application_name in logs, log export', 'Decide six flagged objects (report quirks, coupon bug, split result sets, atomic order)', 'Resync identity sequences after the data load']],
    ['ETL & kit', C.violet, ['Create PostgreSQL connection objects; re-validate mappings; run one session', 'Confirm connector specifics for your PowerCenter version', 'Run the Windows scripts once on Windows; move hooks for Kiro CLI 3.0']],
  ];
  cols.forEach(([h, col, items], i) => {
    const x = 0.6 + i * 4.1;
    s.addShape(pres.shapes.ROUNDED_RECTANGLE, { x, y: 1.75, w: 3.85, h: 4.75, rectRadius: 0.08, fill: { color: C.mist }, line: { color: C.mist }, shadow: shadow() });
    s.addShape(pres.shapes.ROUNDED_RECTANGLE, { x: x + 0.2, y: 1.95, w: 3.45, h: 0.6, rectRadius: 0.06, fill: { color: col }, line: { color: col } });
    s.addText(h, { x: x + 0.2, y: 1.95, w: 3.45, h: 0.6, fontFace: HF, fontSize: 17, bold: true, color: C.paper, align: 'center', valign: 'middle', margin: 0, isTextBox: true });
    items.forEach((t, j) => {
      const y = 2.8 + j * 1.2;
      circleNum(s, x + 0.25, y + 0.05, j + 1, { d: 0.4, size: 13, fill: C.amber });
      s.addText(t, { x: x + 0.8, y, w: 2.85, h: 1.05, fontFace: BF, fontSize: 13, color: C.text, valign: 'top', margin: 0, isTextBox: true });
    });
  });
  footer(s, n);
});

// 15 — Close
slides.push((s) => {
  s.background = { color: C.ink };
  s.addText('Guarded. Tested. Traceable.', { x: 0.8, y: 1.4, w: 11.7, h: 1.0, fontFace: HF, fontSize: 42, bold: true, color: C.paper, margin: 0, isTextBox: true });
  const msgs = [['Faithful', 'Behaviour parity by rule; every deviation flagged for a business decision'], ['Proven', '693 automated checks and a coverage gate on the real target database'], ['Safe', 'Deterministic guardrails around the agent, the tools and the database'], ['Accountable', 'One run id, tamper-evident audit trail, lineage — locally or in AWS']];
  msgs.forEach(([h, b], i) => {
    const y = 2.8 + i * 0.95;
    circleNum(s, 0.8, y + 0.08, i + 1, { d: 0.55, size: 18 });
    s.addText([{ text: h + '  ', options: { bold: true, color: C.amber, fontSize: 20 } }, { text: b, options: { color: 'E3EEF0', fontSize: 17 } }],
      { x: 1.6, y, w: 11, h: 0.7, fontFace: BF, valign: 'middle', margin: 0, isTextBox: true });
  });
  s.addText('Details: README.md · docs/Technical_Architecture.docx · docs/SQL_Migration_User_Guide.docx · docs/Reporting_Analytics_SQL_User_Guide.docx', { x: 0.8, y: 6.7, w: 11.7, h: 0.35, fontFace: BF, fontSize: 12, color: '9FBFC6', margin: 0, isTextBox: true });
});

// ---------- build ----------
slides.forEach((build, i) => {
  if (ONLY && ONLY !== i + 1) return;
  const s = pres.addSlide();
  build(s, i + 1);
});
pres.writeFile({ fileName: OUT }).then((f) => console.log('wrote', f));
