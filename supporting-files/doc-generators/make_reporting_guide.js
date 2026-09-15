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
const EX05 = ["-- Pattern RP-05 \u2014 Top-N per group, ties kept", "-- Rules applied: RQ-09 (DENSE_RANK keeps ties and leaves no gaps; ROW_NUMBER would", "--                drop a tied product arbitrarily), RQ-01 (aggregate first), RQ-16", "CREATE OR REPLACE FUNCTION public.report_top_products_per_category(p_from DATE, p_to DATE, p_n INTEGER DEFAULT 3)", "RETURNS TABLE(category VARCHAR(100), sku VARCHAR(50), units BIGINT, rnk BIGINT)", "LANGUAGE sql STABLE", "AS $$", "    WITH product_units AS (", "        SELECT p.category, p.sku, SUM(ol.quantity)::BIGINT AS units", "        FROM   public.order_lines ol", "        JOIN   public.orders   o ON o.order_id = ol.order_id", "        JOIN   public.products p ON p.product_id = ol.product_id", "        WHERE  o.created_at >= p_from AND o.created_at < p_to", "          AND  o.status NOT IN ('Cancelled', 'Refunded')", "        GROUP  BY p.category, p.sku", "    ),", "    ranked AS (", "        SELECT pu.*, DENSE_RANK() OVER (PARTITION BY pu.category ORDER BY pu.units DESC) AS rnk", "        FROM   product_units pu", "    )", "    SELECT r.category, r.sku, r.units, r.rnk", "    FROM   ranked r", "    WHERE  r.rnk <= p_n", "    ORDER  BY r.category, r.rnk, r.sku;", "$$;", "-- SELECT * FROM public.report_top_products_per_category('2025-01-01', '2026-01-01', 1);"];
const EX01 = ["-- Pattern RP-01 \u2014 Revenue by period with gap filling", "-- Rules applied: RQ-05 (half-open range, generate_series fills empty months),", "--                RQ-14 (one revenue definition), RQ-03 (COALESCE for empty periods)", "-- Grain: one row per calendar month in [p_from, p_to), even months with no orders.", "CREATE OR REPLACE FUNCTION public.report_revenue_by_month(p_from DATE, p_to DATE)", "RETURNS TABLE(period_start DATE, order_count INTEGER, revenue NUMERIC(19,4))", "LANGUAGE sql STABLE", "AS $$", "    WITH months AS (", "        SELECT gs::DATE AS period_start", "        FROM   generate_series(date_trunc('month', p_from::TIMESTAMP),", "                               p_to::TIMESTAMP - INTERVAL '1 day', INTERVAL '1 month') gs", "    ),", "    revenue_orders AS (                       -- the single definition of \"revenue\"", "        SELECT date_trunc('month', o.created_at)::DATE AS period_start, o.total_amount", "        FROM   public.orders o", "        WHERE  o.created_at >= p_from AND o.created_at < p_to   -- half-open, never BETWEEN", "          AND  o.status NOT IN ('Cancelled', 'Refunded')", "    )", "    SELECT m.period_start,", "           COUNT(r.total_amount)::INTEGER,                      -- COUNT(col): 0 for empty months", "           COALESCE(SUM(r.total_amount), 0)::NUMERIC(19,4)     -- SUM over no rows is NULL", "    FROM   months m", "    LEFT   JOIN revenue_orders r ON r.period_start = m.period_start", "    GROUP  BY m.period_start", "    ORDER  BY m.period_start;", "$$;", "-- SELECT * FROM public.report_revenue_by_month('2025-01-01', '2026-01-01');"];
const body = [
  new Paragraph({ children: [new TextRun({ text: 'Reporting & Analytics SQL on PostgreSQL', font: FONT, size: 44, bold: true, color: ACCENT })], spacing: { after: 60 } }),
  new Paragraph({ children: [new TextRun({ text: 'SQL Generation with Kiro — User Guide', font: FONT, size: 32, color: '404040' })], spacing: { after: 80 } }),
  new Paragraph({ children: [t('skill: sql-reporting · Aurora PostgreSQL 17 · September 2026', { size: 20, color: '707070' })],
    border: { bottom: { style: BorderStyle.SINGLE, size: 8, color: ACCENT, space: 6 } }, spacing: { after: 240 } }),

  h1('1. What the skill does'),
  p('The `sql-reporting` skill turns a report request in plain words into **correct, tested PostgreSQL SQL**: KPIs, monthly trends, growth, rankings, top-N, shares, pivots, cohorts, funnels, percentiles, stock balances and subtotals.'),
  bullet('It first pins down **what the number means** (which orders count, which period, which time zone, what happens with ties).'),
  bullet('It writes the report as a **parameterized function** you can call from any SQL client or BI tool.'),
  bullet('It **checks the numbers** (parts add up to totals, no duplicate rows, empty periods shown) and adds **automatic tests**.'),
  note('A report that runs is not a report that is right. Each of the 24 rules in this guide exists because it changed a real number — for example, summing order totals over order lines turns 4 999 into 8 309.'),

  h1('2. Before you start'),
  table([3000, 6026], ['You need', 'Why'], [
    ['Kiro IDE or Kiro CLI with this workspace open', 'The skill lives in `.kiro/skills/sql-reporting/`'],
    ['The converted schema', '`generated/schema.sql` (or your own PostgreSQL tables); Kiro reads it to learn tables and grains'],
    ['A PostgreSQL 15+ TEST database', 'Tests create functions and data; the name must contain test, dev, sandbox or local'],
    ['psql and Python 3.9+', 'Run the tests and the coverage check (Windows: PowerShell 5.1+, python.exe on PATH)'],
    ['Optional: PostgreSQL MCP server', 'Lets Kiro read exact column types from the live database (read-only)'],
  ]),
  gap(),

  h1('3. How to ask for a report'),
  table([2600, 6426], ['Where', 'What to do'], [
    ['Kiro IDE chat', 'Type the request, e.g. `Monthly revenue for 2025 with empty months as 0` — or force the skill with `/sql-reporting …`'],
    ['Kiro CLI', '`kiro-cli chat --agent sql-migration-agent`, then type the request'],
    ['One command', '`kiro-cli chat --no-interactive --agent sql-migration-agent "Top 3 products per category for 2025, ties kept"`'],
    ['Review an existing query', '`Review this dashboard query:` + paste the SQL'],
  ]),
  gap(),
  label('A good request answers five questions'),
  table([2200, 3400, 3426], ['Question', 'Example answer', 'If you leave it out'], [
    ['Grain', 'one row per month per category', 'Kiro asks, or writes its assumption into the header'],
    ['Measure', 'revenue = order line quantity × unit price, excluding cancelled and refunded', 'Kiro uses the shared revenue definition and says so'],
    ['Period', '1 Jan 2025 up to (not including) 1 Jan 2026, UTC', 'half-open range; time zone asked'],
    ['Empty periods', 'show months with no sales as 0', 'shown as 0 by default (gap filling)'],
    ['Ties and order', 'keep ties; order by revenue, then product', 'ties kept with DENSE_RANK; a key breaks remaining ties'],
  ]),
  gap(),

  h1('4. What Kiro does, step by step'),
  ...steps([
    '**Pin down the specification** — grain, measures, dimensions, period, ordering; written as the header comment of the SQL.',
    '**Learn the schema** — which table holds the measure, which joins multiply rows (order → lines).',
    '**Pick the pattern** — one of the 15 tested report shapes (section 6), combined where needed.',
    '**Write the SQL** — one CTE per stage, explicit casts, delivered as `report_<name>(p_from, p_to, …)`.',
    '**Check the numbers** — totals reconcile, no duplicate keys, empty periods and ties behave, query plan reviewed.',
    '**Test it** — tagged tests with hand-computed expected values, run on the test database.',
    '**Deliver** — specification, SQL, example call, checks performed and any assumption for you to confirm.',
  ]),

  h1('5. What you get back'),
  table([2600, 6426], ['Part', 'Example'], [
    ['Specification header', '`-- Grain: one row per calendar month in [p_from, p_to), even months with no orders.`'],
    ['The report function', '`CREATE OR REPLACE FUNCTION public.report_revenue_by_month(p_from DATE, p_to DATE) …`'],
    ['How to call it', "`SELECT * FROM public.report_revenue_by_month('2025-01-01', '2026-01-01');`"],
    ['Checks performed', 'sum of months = one-line total; July 2025 present with 0; no duplicate months'],
    ['Assumptions to confirm', 'cancelled and refunded orders excluded; UTC month boundaries'],
  ]),
  gap(),
  label('Example — monthly revenue with gap filling (pattern RP-01)'),
  ...codeblock(EX01),

  h1('6. Report catalog — 15 tested patterns'),
  p('Every pattern has a worked example in `.kiro/skills/sql-reporting/references/examples/` that runs in the self-test. Use the example prompt, or combine patterns ("monthly revenue per category with YoY growth" = RP-01 + RP-02 + RP-04).'),
  table([700, 2300, 2300, 3726], ['ID', 'Pattern', 'Function', 'Try asking'], [
    ['RP-01', 'Measure by period, gaps filled', '`report_revenue_by_month`', 'Monthly revenue for 2025, empty months as 0'],
    ['RP-02', 'Measure by dimension (child table)', '`report_category_revenue`', 'Revenue by category with share of total'],
    ['RP-03', 'Running total, moving average', '`report_running_revenue`', 'Cumulative revenue and 3-month moving average'],
    ['RP-04', 'Period over period (MoM, YoY)', '`report_revenue_growth`', 'Month-over-month and year-over-year growth for 2025'],
    ['RP-05', 'Top-N per group', '`report_top_products_per_category`', 'Top 3 products per category, ties kept'],
    ['RP-06', 'Ranking, share, Pareto / ABC', '`report_customer_pareto`', 'Which customers make 80% of revenue?'],
    ['RP-07', 'Distribution statistics', '`report_order_value_stats`', 'Average, median and 90th percentile order value'],
    ['RP-08', 'Pivot (columns per value)', '`report_orders_by_month_status`', 'Orders per month with one column per status'],
    ['RP-09', 'Cohort retention', '`report_cohort_retention`', 'Retention by first-purchase month'],
    ['RP-10', 'Balance as of a date', '`report_stock_as_of`', 'Stock on hand at 30 June'],
    ['RP-11', 'Funnel', '`report_funnel`', 'Checkout conversion: view → cart → order'],
    ['RP-12', 'Gaps and islands (streaks)', '`report_customer_activity_streaks`', 'Longest run of consecutive active months per customer'],
    ['RP-13', 'Subtotals and grand total', '`report_revenue_rollup`', 'Revenue by category and product with subtotals'],
    ['RP-14', 'First / last per group', '`report_customer_first_last_order`', 'First and latest order per customer'],
    ['RP-15', 'Histogram / buckets', '`report_order_value_histogram`', 'Order count by value band of 100'],
  ]),
  gap(),

  h1('7. The 24 correctness rules in plain words'),
  p('Kiro applies these automatically. Knowing them helps you read a report and review someone else\'s query. Rule ids appear in SQL comments and test names.'),
  label('Counting and summing'),
  table([900, 4200, 3926], ['Rule', 'In plain words', 'What goes wrong otherwise'], [
    ['RQ-01', 'Add up at the finest level first, then join', 'order totals repeated once per order line'],
    ['RQ-02', 'One definition per measure, reused everywhere', 'two reports disagree on "revenue"'],
    ['RQ-14', 'Exclude cancelled/refunded/test orders the same way everywhere', '18 orders in one report, 15 in another'],
    ['RQ-24', 'Count rows, non-empty values or distinct values — on purpose', 'customers counted once per order'],
    ['RQ-13', 'Stock and balances: take the last value on the date, never add days up', '53 units reported as 153'],
    ['RQ-23', 'Never average averages', 'average order value 249 instead of the true 333'],
  ]),
  gap(),
  label('Numbers and empty data'),
  table([900, 4200, 3926], ['Rule', 'In plain words', 'What goes wrong otherwise'], [
    ['RQ-03', 'Empty groups show 0; growth from zero is empty, not an error', 'division-by-zero error or missing rows'],
    ['RQ-04', 'Divide in decimals, round only at the end', '7 / 2 = 3; rounded parts do not add up'],
    ['RQ-19', 'Money is NUMERIC, never floating point', '0.1 + 0.2 is not 0.3'],
    ['RQ-10', 'Say which percentile: interpolated or an actual value', 'median of 1,2,3,4 is 2.5 or 2'],
  ]),
  gap(),
  label('Time'),
  table([900, 4200, 3926], ['Rule', 'In plain words', 'What goes wrong otherwise'], [
    ['RQ-05', 'Periods are "from … up to but not including"; empty periods are filled', 'orders after midnight on the last day vanish'],
    ['RQ-06', 'Group by the report\'s time zone', '02:30 UTC on 1 July is still 30 June in New York'],
    ['RQ-07', 'Say whether weeks start on Monday or Sunday', 'a Sunday lands in a different week'],
    ['RQ-11', 'Compare to the previous period only on a complete series', 'August compared with June after a gap'],
    ['RQ-17', 'Cohorts: first qualifying event; divide by cohort size', 'retention above 100% or too low'],
  ]),
  gap(),
  label('Rankings, layout and presentation'),
  table([900, 4200, 3926], ['Rule', 'In plain words', 'What goes wrong otherwise'], [
    ['RQ-08', 'Running totals state their window exactly', '20, 20, 30 instead of 10, 20, 30'],
    ['RQ-09', 'Choose how ties are ranked', 'a tied product silently drops out of the top 3'],
    ['RQ-16', 'Every sort has a final tie-breaker', 'different rows each time the report runs'],
    ['RQ-12', 'Pivots have an "other" and a "total" column', 'unexpected statuses disappear'],
    ['RQ-15', 'Subtotal rows are marked, not guessed from empty values', 'a real "unknown" category shown as a subtotal'],
    ['RQ-18', 'Funnels count people, list every step', '7 view events reported instead of 5 users'],
    ['RQ-22', 'Tidy text before grouping (trim, lower case)', '"Widgets", " widgets" and "WIDGETS" as three groups'],
  ]),
  gap(),
  label('Delivery and speed'),
  table([900, 4200, 3926], ['Rule', 'In plain words', 'What goes wrong otherwise'], [
    ['RQ-21', 'Deliver as a parameterized read-only function (or view)', 'copy-pasted SQL that nobody can test'],
    ['RQ-20', 'Filter early, index the filters, check the plan, materialize heavy dashboards (manual check)', 'slow dashboards on production volumes'],
  ]),
  gap(),

  h1('8. Walkthrough — top products per category'),
  label('1 · You type'),
  cmd('Top products per category by units sold for 2025. Keep ties. Exclude cancelled and refunded orders.'),
  label('2 · Kiro confirms the specification'),
  table([2600, 6426], ['Item', 'Decision'], [
    ['Grain', 'one row per product within its category, only ranks 1..N'],
    ['Measure', 'units = SUM(order_lines.quantity) — measured at line level (RQ-01)'],
    ['Period', "`[p_from, p_to)` — e.g. '2025-01-01' up to '2026-01-01' (RQ-05)"],
    ['Ties', 'DENSE_RANK: tied products share a rank, nothing is dropped (RQ-09)'],
    ['Order', 'category, rank, then SKU as tie-breaker (RQ-16)'],
  ]),
  gap(),
  label('3 · Kiro writes the function'),
  ...codeblock(EX05),
  label('4 · Kiro checks and tests it'),
  table([4200, 4826], ['Check', 'Result on the sample data'], [
    ['Top 1 per category', 'Gadgets: GP-002 = 15 units · Widgets: BW-003 = 30 units'],
    ['Top 2 per category', '4 rows'],
    ['Ties with DENSE_RANK', 'two products with equal units both get rank 1'],
    ['No duplicate (category, sku)', 'grain check returns no rows'],
  ]),
  gap(),
  label('5 · You call it'),
  cmd("SELECT * FROM public.report_top_products_per_category('2025-01-01', '2026-01-01', 3);"),

  h1('9. Testing your reports'),
  p('Tests run on the shared test engine. Expected values are computed **by hand or with a separate query**, never copied from the report\'s own output. Test names carry the rule and pattern ids they prove.'),
  ...codeblock([
    'DO $$',
    "DECLARE s TEXT := 'my_reports';",
    'BEGIN',
    "    PERFORM test_assert_equal(s, 'July 2025 has no orders and shows 0 [RQ-05] [RP-01]',",
    "        (SELECT r.revenue FROM public.report_revenue_by_month('2025-01-01', '2026-01-01') r",
    "         WHERE r.period_start = '2025-07-01'), 0::NUMERIC(19,4));",
    'EXCEPTION WHEN OTHERS THEN PERFORM test_error(s, SQLERRM);',
    'END $$;',
  ]),
  table([4000, 5026], ['Run', 'Command'], [
    ['The reporting skill self-test (15 patterns, 88 checks)', '`bash .kiro/skills/sql-reporting/scripts/run_skill_tests.sh`  ·  Windows: `.kiro\\skills\\sql-reporting\\scripts\\run_skill_tests.cmd`'],
    ['Everything in the project', '`bash supporting-files/run_tests.sh`'],
    ['Only the three skills', '`bash supporting-files/run_tests.sh --skill`'],
  ]),
  gap(),
  p('The run ends with `RESULT: PASS` and `COVERAGE: PASS` — every rule and pattern has at least one test. Each run has a run id; PostgreSQL shows the test session as `application_name mig:selftest:<first 8 characters>`.'),

  h1('10. Fast dashboards on Aurora PostgreSQL'),
  table([3000, 6026], ['Technique', 'How'], [
    ['Keep filters index-friendly', "`created_at >= p_from AND created_at < p_to` — not `date_trunc('month', created_at) = …`"],
    ['Index what you filter on', '`CREATE INDEX ON orders (status, created_at);`'],
    ['Check the plan', '`EXPLAIN (ANALYZE, BUFFERS) SELECT * FROM report_…(…);` — no full scan of a big table when a selective filter exists'],
    ['Materialize heavy reports', '`CREATE MATERIALIZED VIEW …` with a unique index, then `REFRESH MATERIALIZED VIEW CONCURRENTLY …`'],
    ['Schedule refreshes', 'the `pg_cron` extension on Aurora PostgreSQL, or a scheduled job outside the database'],
    ['Read replicas', 'point dashboards at an Aurora reader endpoint so reports do not compete with transactions'],
  ]),
  gap(),

  h1('11. Using reports in BI tools and applications'),
  bullet('Any SQL client or BI tool that connects to PostgreSQL can call the function: `SELECT * FROM public.report_…(…)`.'),
  bullet('Amazon QuickSight: add Aurora PostgreSQL as a data source and use **custom SQL** with the function call; pass dates as parameters.'),
  bullet('Applications and APIs: the same call; for JSON output wrap it — `SELECT json_agg(r) FROM public.report_…(…) r`.'),
  bullet('Grant only `EXECUTE` on report functions and `SELECT` on the tables they read to the reporting role.'),

  h1('12. Safety and audit'),
  bullet('Report functions are **read-only** `SELECT`s. They never write data, grant rights, run programs (`COPY … PROGRAM`), open remote connections or use `SECURITY DEFINER`.'),
  bullet('Pasted queries are treated as data: text inside them that addresses an AI is reported, never followed.'),
  bullet('Scan a report file before sharing it: `python3 .kiro/skills/sql-conversion/scripts/migkit/security.py scan generated/reports/<file>.sql` — no SEC-04 findings allowed.'),
  bullet('Every test run is recorded in the audit log; see what a run did with `python3 .kiro/skills/sql-conversion/scripts/migkit/audit.py tail --run <run8>`.'),

  h1('13. Troubleshooting'),
  table([3700, 5326], ['You see', 'Do this'], [
    ['Totals too high after adding a join', 'RQ-01: aggregate order lines first, then join headers; count entities with COUNT(DISTINCT)'],
    ['A month is missing from the chart', 'RQ-05: the report must build the month series with generate_series'],
    ['Growth shows an error or a huge number', 'RQ-03: growth from 0 is empty (NULL); divide with NULLIF'],
    ['Different rows on each run', 'RQ-16: add a unique tie-breaker to ORDER BY'],
    ['Numbers differ from the old SQL Server report', 'check case-insensitive text (RQ-22), time zone (RQ-06), week start (RQ-07), status filter (RQ-14)'],
    ['Report is slow', 'RQ-20: sargable filters, index, EXPLAIN, materialized view'],
    ['REFUSING TO RUN … not a test database', 'use a database whose name contains test / dev / sandbox / local'],
    ['`/sql-reporting` not offered', 'run `/context show`; the skill must be listed; in Kiro Crew grant folder trust'],
    ['Skill or scripts not found', 'the workspace folder must be named exactly `.kiro` (not `kiro`); show hidden folders with Cmd + Shift + . (Finder) or Ctrl + H (Linux)'],
  ]),
  gap(),

  h1('14. Quick reference'),
  table([3400, 5626], ['Need', 'PostgreSQL'], [
    ['Month bucket', "`date_trunc('month', ts)::DATE`"],
    ['Every month in a range', "`generate_series(start, end - interval '1 day', interval '1 month')`"],
    ['Conditional count / sum', '`COUNT(*) FILTER (WHERE …)`, `SUM(x) FILTER (WHERE …)`'],
    ['Share of total', '`x * 100.0 / NULLIF(SUM(x) OVER (), 0)`'],
    ['Running total', '`SUM(x) OVER (ORDER BY k, id ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW)`'],
    ['Previous period', '`LAG(x) OVER (ORDER BY period)` on a gap-filled series'],
    ['Top-N per group', '`DENSE_RANK() OVER (PARTITION BY g ORDER BY m DESC)` then `WHERE rnk <= n`'],
    ['Median / percentile', '`percentile_cont(0.5) WITHIN GROUP (ORDER BY x)`'],
    ['Subtotals', '`GROUP BY GROUPING SETS ((a, b), (a), ())` + `GROUPING(col)`'],
    ['Latest row per key', '`DISTINCT ON (key) … ORDER BY key, ts DESC, id DESC`'],
    ['Buckets', '`width_bucket(x, lo, hi, n)`'],
    ['Plan check', '`EXPLAIN (ANALYZE, BUFFERS) SELECT …`'],
  ]),
  gap(),
  p('More detail: `.kiro/skills/sql-reporting/SKILL.md` (procedure), `.kiro/skills/sql-reporting/references/patterns.md` (all rules and patterns), `references/examples/` (15 tested reports), `docs/SQL_Migration_User_Guide.docx` (whole kit).', { spacing: { before: 120 } }),
];
const doc = new Document({
  creator: 'SQLMigrationProject',
  title: 'Reporting and Analytics SQL Generation — User Guide',
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
      children: [t('Reporting & Analytics SQL · User Guide', { size: 16, color: '808080' }),
                 new TextRun({ children: [new Tab(), 'Page '], font: FONT, size: 16, color: '808080' }),
                 new TextRun({ children: [PageNumber.CURRENT], font: FONT, size: 16, color: '808080' })] })] }) },
    children: body,
  }],
});

Packer.toBuffer(doc).then((buf) => { fs.writeFileSync(OUT, buf); console.log('wrote', OUT, buf.length, 'bytes'); });
