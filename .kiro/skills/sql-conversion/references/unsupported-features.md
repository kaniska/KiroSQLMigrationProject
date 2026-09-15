# SQL Server features without a direct PostgreSQL equivalent

Read this when the Step 2 inventory in `SKILL.md` finds one of these constructs.
Every workaround below changes structure. Flag it in the code with
`-- TODO: MANUAL REVIEW REQUIRED — <reason>` and set `"manual_review": true` in
`metadata/migration_log.json`.

Target: Aurora PostgreSQL 17. On Aurora/RDS only AWS-supported extensions can be
installed (`SELECT * FROM pg_available_extensions`).

---

## Cross-database and cross-server access

| T-SQL | PostgreSQL |
|---|---|
| `[server].[db].[schema].[table]`, `OPENQUERY`, linked servers | `postgres_fdw` (foreign tables) or `dblink`; for non-PostgreSQL sources, ETL (AWS DMS, Glue) |
| Three-part names `OtherDb.dbo.Table` | PostgreSQL cannot query across databases → schemas in one database, or `postgres_fdw` |
| MSDTC distributed transactions | Not supported → redesign (saga / outbox pattern) |
| Synonyms | a view, or `search_path` |

## Programmability

| T-SQL | PostgreSQL |
|---|---|
| CLR functions / assemblies | Rewrite in PL/pgSQL (or PL/Python / PL/Perl where available) |
| `EXECUTE AS USER/OWNER` | `SECURITY DEFINER` on the function, always with `SET search_path = public, pg_temp` |
| `##global` temp tables | No equivalent → a regular table in a staging schema with a session/job key, or an unlogged table |
| Table-valued parameters (TVP) | an array of a composite type, or `JSONB` + `jsonb_to_recordset` |
| Multiple result sets from one proc | one function per result set (`SKILL.md` Step 3) |
| `GOTO` | restructure with `LOOP`/`EXIT`/`CONTINUE` and blocks |
| SQL Agent jobs | `pg_cron` (supported on Aurora PostgreSQL) or EventBridge Scheduler + Lambda |
| Database Mail | not in the database → app layer / Amazon SES; `aws_lambda` extension if the database must trigger it |
| `sp_getapplock` | `pg_advisory_xact_lock(hashtext('name'))` |
| `@@IDENTITY` | `RETURNING` (never `lastval()` — like `@@IDENTITY`, it sees trigger inserts) |

## Triggers

| T-SQL | PostgreSQL |
|---|---|
| `INSERTED` / `DELETED` pseudo-tables (statement-level) | `AFTER … FOR EACH STATEMENT` trigger with `REFERENCING NEW TABLE AS inserted OLD TABLE AS deleted` |
| Row-by-row logic over `INSERTED` | `FOR EACH ROW` trigger using `NEW` / `OLD` |
| `INSTEAD OF` triggers on tables | allowed only on views in PostgreSQL → use a `BEFORE` trigger that returns `NULL`, or a view |
| Trigger body inline in `CREATE TRIGGER` | a separate `RETURNS trigger` function plus `CREATE TRIGGER … EXECUTE FUNCTION f()` |

## XML / JSON

```sql
-- FOR XML PATH('item'), ROOT('items')
SELECT xmlelement(NAME items, xmlagg(xmlelement(NAME item, xmlforest(t.name, t.value))))
FROM   t;

-- FOR JSON PATH
SELECT json_agg(json_build_object('name', t.name, 'value', t.value)) FROM t;

-- STRING_AGG(x, ',') WITHIN GROUP (ORDER BY x)
SELECT string_agg(x, ',' ORDER BY x) FROM t;

-- OPENJSON(@json) WITH (Id INT '$.id', Name NVARCHAR(100) '$.name')
SELECT j.id, j.name
FROM   jsonb_to_recordset(p_json) AS j(id INTEGER, name VARCHAR(100));

-- JSON_VALUE(@j, '$.a.b')  →  p_j #>> '{a,b}'        ISJSON(x)  →  x IS JSON (PG 16+)
```

## Bulk load and full-text search

```sql
-- BULK INSERT dbo.Staging FROM 'C:\data\file.csv' WITH (FIELDTERMINATOR = ',', FIRSTROW = 2)
-- Server-side files are not reachable on Aurora → client-side copy:
\copy public.staging FROM 'file.csv' WITH (FORMAT csv, HEADER true)
-- or aws_s3.table_import_from_s3(...) (aws_s3 extension) for S3 objects

-- CONTAINS(Description, 'widget')  /  FREETEXT(...)
WHERE to_tsvector('english', t.description) @@ plainto_tsquery('english', 'widget')
-- index: CREATE INDEX ix_t_description_fts ON t USING GIN (to_tsvector('english', description));
-- Plain substring semantics instead: ILIKE '%widget%' (+ pg_trgm GIN index)
```

## Data types

| T-SQL | PostgreSQL |
|---|---|
| `ROWVERSION` / `TIMESTAMP` column (optimistic locking) | the `xmin` system column, or `updated_at` / an integer version column maintained by a trigger |
| `HIERARCHYID` | `ltree` extension, or an adjacency list + recursive CTE |
| `SQL_VARIANT` | `JSONB` or `TEXT` plus a type-tag column |
| `GEOGRAPHY` / `GEOMETRY` | PostGIS (`geography` / `geometry`) |
| `NEWSEQUENTIALID()` | no core equivalent in 17 (`uuidv7()` arrives in PG 18) → `gen_random_uuid()`; accept the index-locality loss |
| `DATETIME` values ending in `.997/.999` | SQL Server rounds DATETIME to 1/300 s; `TIMESTAMP(3)` does not → flag range predicates using `23:59:59.997` |

## Query syntax

| T-SQL | PostgreSQL |
|---|---|
| `PIVOT` / `UNPIVOT` | conditional aggregation: `SUM(x) FILTER (WHERE k = 'A') AS a`; `crosstab()` (tablefunc) for dynamic columns; `UNPIVOT` → `CROSS JOIN LATERAL (VALUES …)` |
| `CROSS APPLY` / `OUTER APPLY` | `CROSS JOIN LATERAL` / `LEFT JOIN LATERAL … ON TRUE` |
| `TOP (n) WITH TIES` | `ORDER BY … FETCH FIRST n ROWS WITH TIES` (PG 13+) |
| `TOP (n) PERCENT` | `LIMIT (SELECT CEIL(COUNT(*) * n / 100.0) FROM …)` — SQL Server rounds **up** |
| `WITH (NOLOCK)` / `READ UNCOMMITTED` | remove — PostgreSQL never reads uncommitted data (MVCC) |
| Query hints `OPTION (RECOMPILE / MAXDOP / MAXRECURSION)` | remove; keep an explicit depth predicate for recursion |
| Index hints `WITH (INDEX(ix))` | remove (no hints in core PostgreSQL) |
| Clustered indexes | none; `CLUSTER` is a one-off physical sort, not maintained |

## AWS SCT extension pack (`aws_sqlserver_ext`)

AWS SCT can emit calls into its `aws_sqlserver_ext` schema, which emulates SQL Server
built-ins (`patindex`, `sys.*` views, date helpers). Generated code in this project
uses **native** PostgreSQL only: every call into the pack is a runtime dependency
that must be installed and upgraded alongside the application. If you receive SCT
output, replace `aws_sqlserver_ext.*` calls with the native mappings in the
steering file wherever they are exact.
