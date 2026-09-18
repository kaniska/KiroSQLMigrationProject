---
inclusion: always
---

# SQL Server → Apache Iceberg on Amazon S3 (Athena / Glue / Spark) — Conversion Rules

Rules for landing SQL Server tables and set-based logic in **Apache Iceberg tables on S3**
registered in the AWS Glue Data Catalog, queried with Amazon Athena (engine v3) and written by
AWS Glue (Spark) jobs. They complement `governance.md` and reuse `migration.md` where the SQL
dialects agree. Implemented by `.kiro/skills/sql-conversion-iceberg/SKILL.md`; corner cases
`IB-nn` in that skill's `references/corner-cases.md`. Rule ids `[I-n]`.

Iceberg is a **table format on object storage**: it holds curated LEFT-EDGE and MIDDLE data,
served to BI through Athena views or Redshift Spectrum, and loaded by Spark jobs. There is no
procedural engine — stored procedures become Glue jobs or stay on Aurora (placement decided by
`migration-assessment`).

## Hard rules

1. **[I-1] No engine features that Iceberg lacks.** `IDENTITY`, PK/UNIQUE/FK/CHECK enforcement,
   column defaults, computed columns, indexes, triggers, cursors and table variables are not part
   of the table format: they are recorded in the ledger as "applied by the load job" or
   "validated by a query", never silently dropped [IB-01…IB-08].
2. **[I-2] Types follow the Iceberg spec.** All character types → `string` (the source length is
   kept in a column `COMMENT` and validated by `V-006`); `TINYINT`/`SMALLINT` → `int`; `BIT` →
   `boolean`; `MONEY` → `decimal(19,4)`; `DECIMAL(p,s)` with `p ≤ 38`; `FLOAT`/`REAL` →
   `double`/`float`; `DATETIME*` → `timestamp` (microseconds in the spec, milliseconds when written
   by Athena); `DATETIMEOFFSET` → `timestamp` normalised to UTC (Athena Iceberg DDL has no
   time-zone type); `TIME` → `string`; `UNIQUEIDENTIFIER` → `string`; binary/`ROWVERSION` →
   `binary`; `GEOGRAPHY` → `binary` holding WKB (or `string` WKT) with a spatial decision;
   `XML`/`SQL_VARIANT`/`HIERARCHYID` → `string` with manual review [IB-10…IB-22].
3. **[I-3] Partitioning is a design decision.** Emit `PARTITIONED BY` only from the design file
   (`year|month|day|hour(col)`, `bucket(N, col)`, `truncate(L, col)`); never guess from column
   names. Index columns are recorded as write-order candidates [IB-30, IB-33].
4. **[I-4] Two DDL dialects, one catalog.** Athena: `CREATE TABLE db.t (…) PARTITIONED BY (…)
   LOCATION 's3://…/' TBLPROPERTIES ('table_type'='ICEBERG', 'format'='parquet')`. Spark:
   `CREATE TABLE glue_catalog.db.t (…) USING iceberg PARTITIONED BY (days(col), …)` with
   `format-version 2`. Names are lower-case snake_case because the Glue catalog lower-cases
   identifiers [IB-31, IB-32, IB-34].
5. **[I-5] Schema evolution is by spec.** Allowed in place: `int → long`, `float → double`,
   `decimal(p,s) → decimal(p+,s)`, add/rename/reorder columns. Anything else (string → int,
   narrowing) is a new column plus backfill [IB-35].
6. **[I-6] Functions.** `ISNULL` → `coalesce`; `IIF` → `if()`/`CASE`; `GETDATE()` →
   `current_timestamp()`; `DATEADD(day, n, d)` → `date_add(d, n)` (days) or `timestampadd(unit, n, ts)`;
   `DATEDIFF(day, a, b)` → `datediff(b, a)` (argument order reversed) or `timestampdiff`; `CHARINDEX(x, s)`
   → `instr(s, x)` (arguments swapped); `LEN` → `length`; `TOP n` → `LIMIT n`; `'a' + b` → `concat`/`||`;
   `STRING_AGG` → `listagg` (Athena, Spark 4) or `array_join(sort_array(collect_list(x)), ',')`;
   `NEWID()` → `uuid()`; `TRY_CAST` is kept; `CONVERT(type, x, style)` → `CAST` / `date_format`;
   integer division must be explicit (`div`) because `/` is floating-point in Spark [IB-40…IB-52].
7. **[I-7] MERGE writes must be safe.** `MERGE INTO` (Spark and Athena) fails when a target row
   matches more than one source row: deduplicate the source (`row_number() … = 1`) or prove
   uniqueness; `WHEN NOT MATCHED BY SOURCE` only on Spark 3.4+/Iceberg 1.3+ (not Athena). Row-level
   `UPDATE`/`DELETE` produce delete files: schedule `OPTIMIZE … REWRITE DATA` and `VACUUM`
   [IB-60…IB-62].
8. **[I-8] Views are served, not ported.** BI edge views become Athena views (Trino SQL) or Glue
   Data Catalog multi-dialect views; Spark SQL is for jobs. Recursive CTEs run on Athena
   (`WITH RECURSIVE`), not on Spark before 4.1 [IB-64, IB-70].
9. **[I-9] Jobs are generated from the template**, not hand-typed: Glue 5.x, `--datalake-formats
   iceberg`, catalog configuration through Spark confs, arguments for database/table/keys/run id,
   idempotent `MERGE INTO`, row counts and the run id printed for the audit, no credentials, no
   `boto3` identity calls, no shell [IB-71, IB-72].
10. **[I-10] Prove it.** Static checks (`iceberg_tool.py check`) must be clean; jobs must compile
    (`py_compile`); execution evidence comes from Athena against a database whose name contains
    test/dev/sandbox/local, or the check stays listed as unexecuted (`V-004`); row-count
    reconciliation uses snapshot time travel (`FOR TIMESTAMP AS OF`) [IB-73, IB-80].
11. **[I-11] Done means packaged** (process rule): DDL for both dialects, job script, rule ledger,
    classification and validation manifest with hashes and the run id.

## Datatype map (SQL Server → Iceberg / Athena / Spark)

| SQL Server | Iceberg (Athena DDL / Spark DDL) | Notes |
|---|---|---|
| `TINYINT`/`SMALLINT`/`INT` | `int` | no small integer types |
| `BIGINT` | `bigint` | |
| `BIT` | `boolean` | |
| `DECIMAL(p,s)`/`NUMERIC` | `decimal(p,s)` | p ≤ 38 |
| `MONEY`/`SMALLMONEY` | `decimal(19,4)`/`decimal(10,4)` | |
| `FLOAT`/`REAL` | `double`/`float` | |
| `CHAR`/`VARCHAR`/`NCHAR`/`NVARCHAR`/`TEXT`/`NTEXT`/`SYSNAME` | `string` | length kept in COMMENT; validated by V-006 |
| `DATE` | `date` | |
| `TIME` | `string` | Athena/Spark Iceberg DDL has no time type |
| `DATETIME`/`DATETIME2`/`SMALLDATETIME` | `timestamp` | µs (Spark) / ms (Athena) |
| `DATETIMEOFFSET` | `timestamp` (UTC) | offset lost; keep a `tz_offset_minutes` column when needed |
| `UNIQUEIDENTIFIER` | `string` | |
| `VARBINARY`/`BINARY`/`IMAGE`/`ROWVERSION` | `binary` | |
| `GEOGRAPHY`/`GEOMETRY` | `binary` (WKB) or `string` (WKT) | Athena geospatial functions read WKB/WKT |
| `XML`, `SQL_VARIANT`, `HIERARCHYID` | `string` | manual review |

## Validation checklist

- [ ] `iceberg_tool.py check` reports 0 problems on every DDL/SQL/job file *(auto)*
- [ ] every table has an explicit partition decision (or none, recorded) and a location/catalog
- [ ] ledger explains lost lengths, identity, constraints, defaults and computed columns
- [ ] job compiles and its security scan is clean; reruns are idempotent (`V-033`)
- [ ] execution evidence on a test database (Athena) or `V-004` listed as unexecuted
