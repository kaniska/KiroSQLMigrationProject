# Where SQL hides in a PowerCenter XML export

A repository export (`pmrep objectexport` / Designer *Export Objects*) is one XML document:

```
POWERMART
└── REPOSITORY (DATABASETYPE = the repository's own DB — leave it alone)
    └── FOLDER
        ├── SOURCE  (DATABASETYPE, DBDNAME, OWNERNAME) ── SOURCEFIELD (DATATYPE = native DB type)
        ├── TARGET  (DATABASETYPE)                    ── TARGETFIELD (DATATYPE = native DB type)
        ├── TRANSFORMATION REUSABLE="YES"              ── TABLEATTRIBUTE   ← reusable lookups / SPs
        ├── MAPPLET / MAPPING
        │   ├── TRANSFORMATION (TYPE=…)                ── TABLEATTRIBUTE   ← most SQL lives here
        │   ├── INSTANCE TYPE="SOURCE|TARGET"          ── TABLEATTRIBUTE   ← target Update Override, Pre/Post SQL
        │   ├── INSTANCE … ASSOCIATED_SOURCE_INSTANCE  (which sources feed a Source Qualifier)
        │   ├── CONNECTOR (FROMINSTANCE/FROMFIELD → TOINSTANCE/TOFIELD)
        │   └── MAPPINGVARIABLE (NAME="$$PARAM")
        ├── CONFIG (session config object)            ── ATTRIBUTE        ← "On Pre-Post SQL error", "Enable high precision"
        ├── SESSION (MAPPINGNAME)          child order fixed by powrmart.dtd:
        │   ├── SESSTRANSFORMATIONINST                 ── ATTRIBUTE        ← session-level overrides (win over mapping level)
        │   ├── CONFIGREFERENCE, SESSIONCOMPONENT
        │   ├── SESSIONEXTENSION TYPE="READER|WRITER"  ── ATTRIBUTE        ← writer settings (Target load type, Truncate…);
        │   │     └── CONNECTIONREFERENCE (CONNECTIONSUBTYPE, VARIABLE)        PowerExchange: SQL Override, Pre-SQL, Post-SQL
        │   └── ATTRIBUTE (Parameter Filename, Treat source rows as, …)
        └── WORKFLOW ── TASKINSTANCE, WORKFLOWLINK, ATTRIBUTE
```

Element placement varies slightly between PowerCenter versions, so the tool matches
attributes **by `NAME`, wherever they are**, and derives the owning transformation, mapping or
session from the ancestors.

## What real exports look like (verified on public PowerCenter 10.x exports)

Checked against 14 exports from public GitHub repositories (HHS/Informatica — Unlicense, three of
them kept in `references/corpus/`; others used read-only) and the Informatica 10.4/10.5 docs:

| Aspect | Real exports | Consequence |
|---|---|---|
| Encoding | `<?xml version="1.0" encoding="ISO-8859-1"?>` with `CODEPAGE="Latin1"`, or `Windows-1252` / `MS1252`; UTF-8 is rare | decode with the declared encoding; write back in it; characters outside the code page become `&#x…;` (IC-39) |
| Attribute syntax | `NAME ="Sql Query" VALUE ="…"` — a space before `=` on `TABLEATTRIBUTE`/`ATTRIBUTE`/fields | parsers matching `NAME="` find nothing (IC-39) |
| Line breaks in SQL | `&#xD;&#xA;`; tab `&#x9;`; backslash sometimes `&#x5c;`; `&apos;` `&lt;` `&gt;` | extracted SQL uses LF; converted values are written in the source's style |
| File line endings | LF or CRLF depending on how the file travelled | kept as is |
| DOCTYPE | always `<!DOCTYPE POWERMART SYSTEM "powrmart.dtd">` | the only DTD accepted (IC-41) |
| Lookups | `TRANSFORMATION TYPE="Lookup Procedure"`; session value `Connection Information ="Relational:CONN"` | (IC-40) |
| Writer settings | `SESSIONEXTENSION TYPE="WRITER" SUBTYPE="Relational Writer"` → `ATTRIBUTE NAME="Target load type"` | (IC-19, IC-40) |
| CRCVALUE | on some `SOURCE` elements (e.g. VSAM); "if you modify certain attributes in an element that contains a CRCVALUE code, you cannot import the object" | inject refuses changes to such elements (IC-43) |
| Empty attributes | exported with `VALUE =""` | stay empty (IC-28) |

Import (`pmrep objectimport` with an `impcntl.dtd` control file) validates against `powrmart.dtd`;
Informatica documents which objects and attributes may be edited in an exported file.
PowerExchange for PostgreSQL is a plug-in with its own session properties (`SQL Override`,
`Pre-SQL`, `Post-SQL`, `Filter Override`, `Enable target bulk load`) instead of the relational
Source Qualifier set; relational ODBC targets revert Bulk to Normal load.

## SQL-bearing attributes

| Attribute `NAME` | On | Kind | Notes |
|---|---|---|---|
| `Sql Query` | Source Qualifier (mapping `TABLEATTRIBUTE`, session `ATTRIBUTE`) | SQ override | full SELECT; columns by position = SQ output ports; no `;` |
| `Sql Query` | SQL transformation (`TYPE="SQL"`, query mode) | SQL transformation query | `?Port?` bindings; may return rows to output ports |
| `User Defined Join` | Source Qualifier | join | Informatica `{ A LEFT OUTER JOIN B ON … }` syntax |
| `Source Filter` | Source Qualifier | filter fragment | no `WHERE`; `SourceName.Column` references |
| `Number Of Sorted Ports` | Source Qualifier | (not SQL) | > 0 ⇒ generated `ORDER BY` on the first N ports (collation trap) |
| `Select Distinct` | Source Qualifier | (not SQL) | ignored when `Sql Query` is set |
| `Pre SQL` / `Post SQL` | Source Qualifier, target instance, session target/SQ | statement list | `;`-separated, `\;` = literal semicolon; run on the reader/writer connection |
| `Lookup Sql Override` | Lookup Procedure (mapping/reusable/session) | lookup override | aliases = port names; `ORDER BY … --` |
| `Lookup table name`, `Lookup Source Filter` | Lookup Procedure | name / fragment | `dbo.` prefix; filter without `WHERE` |
| `Connection Information` | Lookup, SP, SQL transformations | (not SQL) | `$DBConnection_X` variables stay |
| `Update Override` | target instance (mapping), session target | update statement | `:TU.Port` references |
| `SQL Override`, `Filter Override`, `Pre-SQL`, `Post-SQL`, `Insert/Update/Delete SQL override` | PowerExchange reader/writer `SESSIONEXTENSION` | override / fragment / statement list | same rules as the relational attributes (IC-40) |
| `Stored Procedure Name`, `Call Text`, `Stored Procedure Type` | Stored Procedure transformation | proc call | Normal (connected/unconnected), Source Pre/Post Load, Target Pre/Post Load |
| `Owner Name`, `Table Name Prefix`, `Source Table Name`, `Target Table Name` | session SQ / target | (names) | `dbo` → target schema |
| `Target load type`, `Truncate target table option` | session target | (not SQL) | Bulk → Normal for PostgreSQL ODBC |
| `Database Type` | SQL transformation | (not SQL) | `Microsoft SQL Server` → `PostgreSQL` |
| `EXPRESSION=` on `TRANSFORMFIELD`, `Update Strategy Expression`, `Group Filter Condition` | Expression, Aggregator, Filter, Router, Update Strategy | **Informatica language** | never converted (`IIF`, `ISNULL`, `DECODE` here are Informatica functions) |

## Informatica tokens that must survive conversion

| Token | Meaning | Rule |
|---|---|---|
| `$$NAME` | mapping parameter / variable (values from the `.prm` file or `MAPPINGVARIABLE` default) | verbatim; the set of names must not change (IC-02) |
| `$DBConnection_X`, `$PMSourceFileDir`, `$Param…` | session / service parameters | verbatim |
| `?Port?` | SQL transformation input binding | verbatim (IC-14) |
| `:TU.Port` | target port in an Update Override | verbatim; the port part follows a column rename (IC-12) |
| `:LKP.name(args)`, `:SP.name(args)` | unconnected lookup / stored procedure calls inside expressions | Informatica language, not SQL — manual review for `:SP.` |
| `{ … }` | user-defined join block | keep braces (IC-06) |
| trailing `--` | suppresses the generated `ORDER BY` in a lookup override | keep (IC-07) |
| `\;` | literal semicolon in Pre/Post SQL | keep (IC-10) |

## Run identifiers for correlation

Informatica's own run id is `$PMWorkflowRunId` (built-in variables also include `$PMWorkflowName`,
`$PMSessionName`, `$PMMappingName`, `$PMFolderName`, `$PMIntegrationServiceName`,
`$PMRepositoryUserName`); there is **no** `$PMSessionRunId`. The migration tools use their own
`MIGRATION_RUN_ID` (audit log, lineage, test sessions). To correlate production runs on the
PostgreSQL side, record the workflow run id in your load-audit table from Post SQL or a
post-session command, after verifying which built-in variables your PowerCenter version expands
in that context.

## Parameter file (`.prm`)

```
[Folder.WF:workflow.ST:session]
$$LAST_RUN_DATE=2025-06-01 00:00:00
$$BATCH_SIZE=100
$DBConnection_Src=CONN_SALESDB_SRC_PG
```
Sections scope values to a workflow/session; the tool merges all `$$` keys for rendering.
Dates: use ISO formats; `mm/dd/yyyy` depends on the PostgreSQL `DateStyle` (IC-26).

## Connection objects (not in the export)

Relational connections (`$DBConnection_X` → connection object) are managed in Workflow Manager,
not in the XML. After migration create PostgreSQL connections (PowerExchange for PostgreSQL or
ODBC with the PostgreSQL driver) with the same names the parameter file assigns, so the XML
needs no further change. PostgreSQL IAM authentication on Aurora needs a token-refreshing
credential source — usually a database password user for the Integration Service instead.
