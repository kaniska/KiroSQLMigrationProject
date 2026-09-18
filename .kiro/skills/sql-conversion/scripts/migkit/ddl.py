"""
migkit.ddl — deterministic SQL tokenizer, CREATE TABLE parser and construct inventory.

Standard library only. Dialects: tsql (SQL Server), postgres (Aurora PostgreSQL), redshift, spark
(Spark SQL / Athena Iceberg DDL). The parser is intentionally conservative: it captures what the
migration skills need (columns in ordinal order with native datatype components, nullability,
defaults, identity, computed columns, PK/UNIQUE/FK/CHECK constraints, indexes, distribution/sort
keys, partition specs) and records anything it could not interpret under `unresolved` instead
of guessing (fail-closed grounding).

  tables = parse_tables(sql_text, dialect="tsql")
  inv    = inventory(sql_text)          # T-SQL construct inventory for placement / complexity
  refs   = references(sql_text)         # objects a routine reads or writes
"""
import re

RESERVED_IDENT = re.compile(r"^[A-Za-z_][A-Za-z0-9_$#]*$")

# ---------------------------------------------------------------- tokenizer
_TOKEN = re.compile(r"""
    (?P<ws>\s+)
  | (?P<lcomment>--[^\n]*)
  | (?P<bcomment>/\*.*?\*/)
  | (?P<str>N?'(?:[^']|'')*')
  | (?P<bracket>\[[^\]]*\])
  | (?P<dquote>"(?:[^"]|"")*")
  | (?P<btick>`[^`]*`)
  | (?P<num>\d+(?:\.\d+)?)
  | (?P<op>::|<>|!=|>=|<=|\|\||[(),;=.<>+\-*/%@])
  | (?P<word>[A-Za-z_][A-Za-z0-9_$#@]*)
  | (?P<other>.)
""", re.S | re.X)


def tokenize(sql: str):
    """Yield (kind, text) skipping whitespace and comments. Identifier quoting is preserved in text."""
    for m in _TOKEN.finditer(sql):
        kind = m.lastgroup
        if kind in ("ws", "lcomment", "bcomment"):
            continue
        yield kind, m.group(0)


def strip_comments(sql: str) -> str:
    out = []
    for m in _TOKEN.finditer(sql):
        if m.lastgroup in ("lcomment", "bcomment"):
            out.append(" ")
        else:
            out.append(m.group(0))
    return "".join(out)


def unquote(ident: str) -> str:
    if len(ident) >= 2 and ident[0] in "[\"`" and ident[-1] in "]\"`":
        return ident[1:-1].replace('""', '"')
    return ident


def split_qualified(name: str):
    """'[dbo].[Orders]' → ('dbo', 'Orders'); 'Orders' → (None, 'Orders'); 'db.dbo.T' → ('dbo','T') with database dropped."""
    parts, cur, depth = [], "", 0
    for ch in name:
        if ch in "[\"`":
            depth = 1 - depth if ch != "[" else depth + 1
        if ch == "]":
            depth = max(0, depth - 1)
        if ch == "." and depth == 0:
            parts.append(cur); cur = ""
        else:
            cur += ch
    parts.append(cur)
    parts = [unquote(p) for p in parts if p != ""]
    if not parts:
        return None, ""
    if len(parts) == 1:
        return None, parts[0]
    return parts[-2], parts[-1]


# ---------------------------------------------------------------- datatype normalisation
TYPE_WITH_LENGTH = {"varchar", "nvarchar", "char", "nchar", "varbinary", "binary", "sysname", "string", "varbyte"}
TYPE_WITH_PRECISION = {"decimal", "numeric", "dec", "number", "float", "datetime2", "datetimeoffset", "time", "timestamp", "interval"}


def parse_datatype(tokens, i):
    """Parse a datatype starting at tokens[i]. Returns (datatype_dict, next_index).
    datatype_dict: {"raw": str, "base": str, "length": int|'MAX'|None, "precision": int|None, "scale": int|None,
                    "args": [str]} — arrays (`int[]`) and `WITH TIME ZONE` are folded into raw/base."""
    parts = []
    base_words = []
    # base name may be schema-qualified (sys.geography) or multi-word (double precision, timestamp with time zone)
    while i < len(tokens) and tokens[i][0] in ("word", "bracket", "dquote", "btick"):
        w = unquote(tokens[i][1])
        lw = w.lower()
        if base_words and lw in ("not", "null", "default", "identity", "constraint", "primary", "unique", "references",
                                 "check", "collate", "as", "generated", "encode", "distkey", "sortkey", "comment",
                                 "with", "without", "persisted", "sparse", "rowguidcol", "filestream", "masked",
                                 "index", "unsigned", "signed", "auto_increment"):
            if lw == "with" and i + 2 < len(tokens) and tokens[i + 1][1].lower() == "time":
                pass                                                   # timestamp WITH time zone
            elif lw == "without" and i + 2 < len(tokens) and tokens[i + 1][1].lower() == "time":
                pass
            else:
                break
        base_words.append(w); parts.append(w); i += 1
        if i < len(tokens) and tokens[i][1] == ".":
            parts.append("."); i += 1
            continue
        if lw in ("with", "without"):
            # consume 'time zone'
            for _ in range(2):
                if i < len(tokens) and tokens[i][0] == "word":
                    base_words.append(tokens[i][1]); parts.append(tokens[i][1]); i += 1
            continue
        if lw in ("double", "character", "bit", "long", "national") and i < len(tokens) and tokens[i][0] == "word" \
                and tokens[i][1].lower() in ("precision", "varying", "large", "object", "varchar", "char", "raw", "varbinary"):
            continue
        break
    args = []
    if i < len(tokens) and tokens[i][1] == "(":
        depth, i = 1, i + 1
        cur = ""
        while i < len(tokens) and depth:
            k, t = tokens[i]
            if t == "(":
                depth += 1
            elif t == ")":
                depth -= 1
                if depth == 0:
                    i += 1; break
            if depth and t == "," and depth == 1:
                args.append(cur.strip()); cur = ""
            else:
                cur += t if not cur or t in ",)" or cur.endswith("(") else " " + t
            i += 1
        if cur.strip():
            args.append(cur.strip())
    # TIMESTAMP(3) WITH TIME ZONE / TIME(0) WITHOUT TIME ZONE after the precision
    if i + 2 < len(tokens) and tokens[i][1].lower() in ("with", "without") and tokens[i + 1][1].lower() == "time" and tokens[i + 2][1].lower() == "zone":
        base_words += [tokens[i][1], "time", "zone"]; parts += [tokens[i][1], "time", "zone"]; i += 3
    # array suffix
    while i < len(tokens) and tokens[i][0] == "bracket" and tokens[i][1] == "[]":
        parts.append("[]"); i += 1
    base = " ".join(w.lower() for w in base_words)
    if base.startswith(("sys.",)):
        base = base[4:]
    tz_suffix = ""
    if base.endswith((" with time zone", " without time zone")) and args:
        idx = base.rfind(" with") if base.endswith(" with time zone") else base.rfind(" without")
        tz_suffix = base[idx:]
        parts = parts[:-3]
    array = parts.count("[]")
    parts = [x for x in parts if x != "[]"]
    raw = "".join(parts) if "." in parts else " ".join(parts)
    if args:
        raw += "(" + ",".join(args) + ")"
    raw += tz_suffix.upper() + "[]" * array
    d = {"raw": raw, "base": base.split(".")[-1] if "." in base else base, "length": None, "precision": None, "scale": None, "args": args}
    if args:
        a0 = args[0].upper()
        if d["base"] in TYPE_WITH_LENGTH or (d["base"] in ("character varying", "character", "bpchar", "text") and len(args) == 1):
            d["length"] = "MAX" if a0 == "MAX" else (int(a0) if a0.isdigit() else a0)
        else:
            if a0.isdigit():
                d["precision"] = int(a0)
            if len(args) > 1 and args[1].strip().lstrip("-").isdigit():
                d["scale"] = int(args[1].strip())
    return d, i


# ---------------------------------------------------------------- CREATE TABLE parser
COLUMN_TERMINATORS = {"constraint", "primary", "unique", "foreign", "check", "index", "period", "distkey", "sortkey", "diststyle", "partitioned", "location", "tblproperties", "using", "with", "comment", "stored", "lifecycle"}


def _find_matching_paren(tokens, i):
    depth = 0
    for j in range(i, len(tokens)):
        if tokens[j][1] == "(":
            depth += 1
        elif tokens[j][1] == ")":
            depth -= 1
            if depth == 0:
                return j
    return -1


def _split_top_level(tokens, start, end, sep=","):
    """Split tokens[start:end] on top-level separators → list of token lists."""
    items, cur, depth = [], [], 0
    for k in range(start, end):
        t = tokens[k][1]
        if t == "(":
            depth += 1
        elif t == ")":
            depth -= 1
        if t == sep and depth == 0:
            items.append(cur); cur = []
        else:
            cur.append(tokens[k])
    if cur:
        items.append(cur)
    return items


def _expr_text(toks):
    out = ""
    for k, t in toks:
        if out and t not in ",)." and not out.endswith("(") and not out.endswith(".") \
                and not (t == "(" and (out[-1].isalnum() or out[-1] == "_")):
            out += " "
        out += t
    return out.strip()


def _ident_list(toks):
    return [unquote(t) for k, t in toks if k in ("word", "bracket", "dquote", "btick")]


def _parse_constraint(toks, table_name):
    """toks: a top-level constraint item. Returns a constraint dict or None."""
    i, name = 0, None
    words = [t.lower() for k, t in toks]
    if words and words[0] == "constraint":
        name = unquote(toks[1][1]); i = 2
    if i >= len(toks):
        return None
    kw = toks[i][1].lower()
    c = {"name": name, "type": None, "columns": [], "ref_table": None, "ref_columns": [], "expression": None, "clustered": None}
    if kw == "primary":
        c["type"] = "PRIMARY KEY"
    elif kw == "unique":
        c["type"] = "UNIQUE"
    elif kw == "foreign":
        c["type"] = "FOREIGN KEY"
    elif kw == "check":
        c["type"] = "CHECK"
    elif kw == "references":                                           # inline column-level FK
        c["type"] = "FOREIGN KEY"
        q, nm = i + 1, ""
        while q < len(toks) and toks[q][1] != "(" and toks[q][1].lower() not in ("on", "not", "null", "default", "constraint"):
            nm += toks[q][1]; q += 1
        c["ref_table"] = nm
        if q < len(toks) and toks[q][1] == "(":
            e2 = _find_matching_paren(toks, q)
            c["ref_columns"] = [unquote(x[0][1]) for x in _split_top_level(toks, q + 1, e2) if x]
        return c
    else:
        return None
    # clustered/nonclustered
    for k, t in toks[i:]:
        if t.lower() in ("clustered", "nonclustered"):
            c["clustered"] = t.lower() == "clustered"
    # first parenthesised list = columns (or expression for CHECK)
    j = i
    while j < len(toks) and toks[j][1] != "(":
        j += 1
    if j < len(toks):
        end = _find_matching_paren(toks, j)
        inner = toks[j + 1:end]
        if c["type"] == "CHECK":
            c["expression"] = _expr_text(inner)
        else:
            c["columns"] = [unquote(x[0][1]) for x in _split_top_level(toks, j + 1, end) if x]
        # REFERENCES
        for r in range(end, len(toks)):
            if toks[r][1].lower() == "references":
                q = r + 1
                nm = ""
                while q < len(toks) and toks[q][1] != "(":
                    nm += toks[q][1]; q += 1
                c["ref_table"] = nm
                if q < len(toks):
                    e2 = _find_matching_paren(toks, q)
                    c["ref_columns"] = [unquote(x[0][1]) for x in _split_top_level(toks, q + 1, e2) if x]
                break
    return c


DEFAULT_STOP = ("not", "null", "constraint", "identity", "primary", "unique", "references", "check", "collate", "encode", "distkey", "sortkey", "comment", "generated")


def _parse_default(toks, j):
    """Default expression starting at toks[j] (after DEFAULT). Returns (text, next_index)."""
    if j < len(toks) and toks[j][1] == "(":
        e = _find_matching_paren(toks, j)
        return _expr_text(toks[j:e + 1]), e + 1
    e = j
    while e < len(toks) and toks[e][1].lower() not in DEFAULT_STOP:
        e += 1
    return _expr_text(toks[j:e]), e


def _parse_column(toks, dialect):
    col = {"name": unquote(toks[0][1]), "datatype": None, "nullable": True, "default": None, "identity": None,
           "computed": None, "collation": None, "inline_constraints": [], "encode": None, "unresolved": []}
    i = 1
    if i < len(toks) and toks[i][1].lower() == "as" and dialect == "tsql":          # computed column
        body = [x for x in toks[i + 1:] if x[1].lower() != "persisted"]
        col["computed"] = _expr_text(body)
        col["datatype"] = {"raw": "computed", "base": "computed", "length": None, "precision": None, "scale": None, "args": []}
        if "persisted" in [t.lower() for k, t in toks]:
            col["computed"] += " PERSISTED"
        return col
    dt, i = parse_datatype(toks, i)
    col["datatype"] = dt
    while i < len(toks):
        k, t = toks[i]; lt = t.lower()
        if lt == "not" and i + 1 < len(toks) and toks[i + 1][1].lower() == "null":
            col["nullable"] = False; i += 2
        elif lt == "null":
            col["nullable"] = True; i += 1
        elif lt == "default":
            col["default"], i = _parse_default(toks, i + 1)
        elif lt == "identity":
            seed, inc = 1, 1
            i += 1
            if i < len(toks) and toks[i][1] == "(":
                e = _find_matching_paren(toks, i)
                nums = [t2 for k2, t2 in toks[i + 1:e] if k2 == "num"]
                if len(nums) >= 2:
                    seed, inc = int(nums[0]), int(nums[1])
                i = e + 1
            col["identity"] = {"seed": seed, "increment": inc, "kind": "IDENTITY"}
        elif lt == "generated":                                        # PostgreSQL identity / generated columns
            j = i + 1
            kind = []
            while j < len(toks) and (toks[j][1].lower() in ("always", "by", "default", "as", "identity", "stored", "virtual")
                                     and not (toks[j][1].lower() == "default" and kind and kind[-1] != "by")):
                kind.append(toks[j][1].lower()); j += 1
            spec = " ".join(kind)
            if "identity" in spec:
                col["identity"] = {"seed": 1, "increment": 1, "kind": "ALWAYS" if "always" in spec else "BY DEFAULT"}
                if j < len(toks) and toks[j][1] == "(":
                    e = _find_matching_paren(toks, j)
                    inner = [t2 for k2, t2 in toks[j + 1:e]]
                    for a, w in enumerate(inner):
                        if w.lower() == "with" and a + 1 < len(inner) and inner[a + 1].isdigit():
                            col["identity"]["seed"] = int(inner[a + 1])
                        if w.lower() == "by" and a + 1 < len(inner) and inner[a + 1].isdigit():
                            col["identity"]["increment"] = int(inner[a + 1])
                    j = e + 1
            elif "as" in kind and j < len(toks) and toks[j][1] == "(":
                e = _find_matching_paren(toks, j)
                col["computed"] = _expr_text(toks[j:e + 1]) + (" STORED" if "stored" in [t2.lower() for k2, t2 in toks[e:e + 2]] else "")
                j = e + 1
                if j < len(toks) and toks[j][1].lower() == "stored":
                    j += 1
            i = j
        elif lt == "collate":
            col["collation"] = unquote(toks[i + 1][1]) if i + 1 < len(toks) else None; i += 2
        elif lt == "encode":
            col["encode"] = toks[i + 1][1].lower() if i + 1 < len(toks) else None; i += 2
        elif lt in ("distkey", "sortkey"):
            col["inline_constraints"].append(lt.upper()); i += 1
        elif lt == "constraint":
            nm = unquote(toks[i + 1][1]) if i + 1 < len(toks) else None
            i += 2
            # inline PRIMARY KEY / UNIQUE / REFERENCES / CHECK / DEFAULT
            if i < len(toks):
                lt2 = toks[i][1].lower()
                if lt2 == "default":
                    col["default"], i = _parse_default(toks, i + 1)
                    col["inline_constraints"].append({"name": nm, "type": "DEFAULT"})
                else:
                    c = _parse_constraint([("word", "constraint"), ("word", nm or "")] + toks[i:], None)
                    if c:
                        if not c["columns"]:
                            c["columns"] = [col["name"]]
                        col["inline_constraints"].append(c)
                    # advance to end of this constraint: until next keyword we know
                    i += 1
                    while i < len(toks) and toks[i][1].lower() not in ("not", "null", "default", "constraint", "identity", "collate", "encode"):
                        i += 1
        elif lt in ("primary", "unique", "references", "check"):
            c = _parse_constraint(toks[i:], None)
            if c:
                if not c["columns"]:
                    c["columns"] = [col["name"]]
                col["inline_constraints"].append(c)
            i += 1
            while i < len(toks) and toks[i][1].lower() not in ("not", "null", "default", "constraint", "identity", "collate", "encode"):
                i += 1
        elif lt in ("clustered", "nonclustered", "sparse", "rowguidcol", "filestream", "persisted", "comment"):
            if lt == "comment" and i + 1 < len(toks):
                col["comment"] = unquote(toks[i + 1][1]).strip("'"); i += 2
            else:
                i += 1
        elif lt == "masked":
            e = i + 1
            if e < len(toks) and toks[e][1].lower() == "with" and e + 1 < len(toks) and toks[e + 1][1] == "(":
                e = _find_matching_paren(toks, e + 1) + 1
            col["unresolved"].append("MASKED WITH (dynamic data masking)"); i = e
        else:
            col["unresolved"].append(_expr_text(toks[i:])); break
    return col


def parse_tables(sql: str, dialect: str = "tsql") -> list:
    """All CREATE TABLE statements → list of table dicts (dialect: tsql | postgres | redshift | spark)."""
    tokens = list(tokenize(sql))
    tables = []
    i = 0
    while i < len(tokens) - 2:
        if tokens[i][1].lower() == "create":
            j = i + 1
            temp = False
            while j < len(tokens) and tokens[j][1].lower() in ("or", "replace", "temp", "temporary", "external", "unlogged", "iceberg", "if", "not", "exists", "global", "local"):
                if tokens[j][1].lower() in ("temp", "temporary"):
                    temp = True
                j += 1
            if j < len(tokens) and tokens[j][1].lower() == "table":
                j += 1
                while j < len(tokens) and tokens[j][1].lower() in ("if", "not", "exists"):
                    j += 1
                nm, q = "", j
                while q < len(tokens) and tokens[q][1] != "(" and tokens[q][1].lower() not in ("as", "using", "with", ";"):
                    nm += tokens[q][1]; q += 1
                schema, name = split_qualified(nm)
                t = {"schema": schema, "name": name, "temporary": temp, "columns": [], "constraints": [], "indexes": [],
                     "distribution": {}, "partition": [], "properties": {}, "unresolved": [], "dialect": dialect}
                if q < len(tokens) and tokens[q][1] == "(":
                    end = _find_matching_paren(tokens, q)
                    ordinal = 0
                    for item in _split_top_level(tokens, q + 1, end):
                        if not item:
                            continue
                        first = item[0][1].lower()
                        if first in ("constraint", "primary", "unique", "foreign", "check"):
                            c = _parse_constraint(item, name)
                            if c:
                                t["constraints"].append(c)
                            else:
                                t["unresolved"].append(_expr_text(item))
                        elif first in ("index", "period", "key"):
                            t["unresolved"].append(_expr_text(item))
                        else:
                            ordinal += 1
                            try:
                                col = _parse_column(item, dialect)
                            except Exception as ex:   # noqa: BLE001 — never guess a column
                                t["unresolved"].append(f"column {_expr_text(item)[:80]}: {type(ex).__name__}")
                                continue
                            col["ordinal"] = ordinal
                            for ic in col["inline_constraints"]:
                                if isinstance(ic, dict) and ic.get("type") in ("PRIMARY KEY", "UNIQUE", "FOREIGN KEY", "CHECK"):
                                    t["constraints"].append(ic)
                                elif ic == "DISTKEY":
                                    t["distribution"]["distkey"] = col["name"]
                                elif ic == "SORTKEY":
                                    t["distribution"].setdefault("sortkey", []).append(col["name"])
                            col["inline_constraints"] = [c for c in col["inline_constraints"] if isinstance(c, dict) and c.get("type") == "DEFAULT"]
                            t["columns"].append(col)
                    # table options after the column list: DISTSTYLE/DISTKEY/SORTKEY, PARTITIONED BY, TBLPROPERTIES, LOCATION, USING, WITH
                    k = end + 1
                    while k < len(tokens) and tokens[k][1] != ";":
                        lt = tokens[k][1].lower()
                        if lt == "create" or (lt == "go"):
                            break
                        if lt == "diststyle" and k + 1 < len(tokens):
                            t["distribution"]["diststyle"] = tokens[k + 1][1].upper(); k += 2; continue
                        if lt == "distkey" and k + 1 < len(tokens) and tokens[k + 1][1] == "(":
                            e = _find_matching_paren(tokens, k + 1); t["distribution"]["distkey"] = _ident_list(tokens[k + 2:e])[0]; k = e + 1; continue
                        if lt in ("sortkey", "compound", "interleaved") and k + 1 < len(tokens):
                            style = lt if lt != "sortkey" else "compound"
                            kk = k + 1 if lt == "sortkey" else k + 2
                            if kk < len(tokens) and tokens[kk][1] == "(":
                                e = _find_matching_paren(tokens, kk); t["distribution"]["sortkey"] = _ident_list(tokens[kk + 1:e]); t["distribution"]["sortstyle"] = style; k = e + 1; continue
                            if kk < len(tokens) and tokens[kk][1].lower() == "auto":
                                t["distribution"]["sortkey"] = "AUTO"; k = kk + 1; continue
                        if lt == "partitioned" and k + 2 < len(tokens) and tokens[k + 2][1] == "(":
                            e = _find_matching_paren(tokens, k + 2)
                            t["partition"] = [_expr_text(x) for x in _split_top_level(tokens, k + 3, e)]; k = e + 1; continue
                        if lt == "location" and k + 1 < len(tokens):
                            t["properties"]["location"] = unquote(tokens[k + 1][1]).strip("'"); k += 2; continue
                        if lt == "using" and k + 1 < len(tokens):
                            t["properties"]["using"] = tokens[k + 1][1].lower(); k += 2; continue
                        if lt == "tblproperties" and k + 1 < len(tokens) and tokens[k + 1][1] == "(":
                            e = _find_matching_paren(tokens, k + 1)
                            for kv in _split_top_level(tokens, k + 2, e):
                                strs = [x[1].strip("'") for x in kv if x[0] == "str"]
                                if len(strs) == 2:
                                    t["properties"][strs[0]] = strs[1]
                            k = e + 1; continue
                        if lt == "on" and dialect == "tsql":
                            t["properties"]["filegroup"] = tokens[k + 1][1] if k + 1 < len(tokens) else None; k += 2; continue
                        if lt == "with" and k + 1 < len(tokens) and tokens[k + 1][1] == "(":
                            e = _find_matching_paren(tokens, k + 1); t["properties"]["with"] = _expr_text(tokens[k + 2:e]); k = e + 1; continue
                        k += 1
                    i = k
                    pk_cols = {c.lower() for con in t["constraints"] if con["type"] == "PRIMARY KEY" for c in con["columns"]}
                    for col in t["columns"]:
                        if col["name"].lower() in pk_cols:
                            col["nullable"] = False
                    tables.append(t)
                    continue
                else:
                    t["unresolved"].append("CREATE TABLE without a column list (CTAS / SELECT INTO) — columns come from the query")
                    tables.append(t)
        i += 1
    # indexes
    for m in re.finditer(r"CREATE\s+(UNIQUE\s+)?(CLUSTERED\s+|NONCLUSTERED\s+)?INDEX\s+([\[\]\w.\"]+)\s+ON\s+([\[\]\w.\"]+)\s*\(([^)]*)\)(\s*INCLUDE\s*\(([^)]*)\))?(\s*WHERE\s+([^;]+?))?(?=\s*(;|GO\b|CREATE\b|$))",
                         strip_comments(sql), re.I | re.S):
        schema, tname = split_qualified(m.group(4))
        idx = {"name": unquote(m.group(3).split(".")[-1]), "unique": bool(m.group(1)), "clustered": (m.group(2) or "").strip().lower() == "clustered",
               "columns": [unquote(c.strip().split()[0]) for c in m.group(5).split(",") if c.strip()],
               "include": [unquote(c.strip()) for c in (m.group(7) or "").split(",") if c.strip()],
               "filter": (m.group(9) or "").strip() or None}
        for t in tables:
            if t["name"].lower() == tname.lower() and (schema is None or t["schema"] is None or t["schema"].lower() == schema.lower()):
                t["indexes"].append(idx)
    return tables


# ---------------------------------------------------------------- construct inventory (T-SQL)
INVENTORY_RULES = [
    ("procedure", r"\bCREATE\s+(OR\s+ALTER\s+)?PROC(EDURE)?\b"),
    ("function", r"\bCREATE\s+(OR\s+ALTER\s+)?FUNCTION\b"),
    ("view", r"\bCREATE\s+(OR\s+ALTER\s+)?VIEW\b"),
    ("trigger", r"\bCREATE\s+(OR\s+ALTER\s+)?TRIGGER\b"),
    ("table_ddl", r"\bCREATE\s+TABLE\b"),
    ("schemabinding", r"\bWITH\s+SCHEMABINDING\b"),
    ("indexed_view", r"\bCREATE\s+UNIQUE\s+CLUSTERED\s+INDEX\b[^;]*\bON\s+[\[\w\].]*v"),
    ("output_params", r"@\w+\s+[\w()]+\s+(OUT|OUTPUT)\b"),
    ("table_valued_param", r"@\w+\s+[\w.\[\]]+\s+READONLY\b"),
    ("return_code", r"\bRETURN\s+(@\w+|-?\d+)\s*;?"),
    ("cte", r"\bWITH\s+[\[\w\]]+\s*(\([^)]*\))?\s*AS\s*\("),
    ("recursive_cte", r"\bUNION\s+ALL\b[\s\S]{0,600}\bJOIN\s+[\[\w\]]+\s+\w+\s+ON\b|\bWITH\s+[\[\w\]]+\s+AS\s*\([\s\S]{0,400}\bUNION\s+ALL\b"),
    ("window_function", r"\b(ROW_NUMBER|RANK|DENSE_RANK|NTILE|LAG|LEAD|FIRST_VALUE|LAST_VALUE|SUM|AVG|COUNT|MIN|MAX)\s*\([^)]*\)\s*OVER\s*\("),
    ("merge", r"\bMERGE\s+(INTO\s+)?[\[\w\].]+"),
    ("dynamic_sql", r"\b(sp_executesql|EXEC(UTE)?\s*\(\s*@)"),
    ("exec_procedure", r"\bEXEC(UTE)?\s+[\[\w\].]+"),
    ("temp_table", r"#\w+"),
    ("global_temp_table", r"##\w+"),
    ("table_variable", r"DECLARE\s+@\w+\s+TABLE\b"),
    ("cursor", r"\bDECLARE\s+\w+\s+(\w+\s+)*CURSOR\b"),
    ("while_loop", r"\bWHILE\b"),
    ("try_catch", r"\bBEGIN\s+TRY\b"),
    ("transaction", r"\bBEGIN\s+TRAN(SACTION)?\b"),
    ("xact_abort", r"\bSET\s+XACT_ABORT\s+ON\b"),
    ("raiserror", r"\bRAISERROR\s*\("),
    ("throw", r"\bTHROW\b"),
    ("identity_insert", r"\bSET\s+IDENTITY_INSERT\b"),
    ("scope_identity", r"\b(SCOPE_IDENTITY|@@IDENTITY|IDENT_CURRENT)\b"),
    ("rowcount", r"@@ROWCOUNT"),
    ("nolock_hint", r"\bWITH\s*\(\s*(NOLOCK|READUNCOMMITTED)"),
    ("lock_hint", r"\bWITH\s*\(\s*(UPDLOCK|HOLDLOCK|TABLOCK|ROWLOCK|XLOCK|SERIALIZABLE|READPAST)"),
    ("query_hint", r"\bOPTION\s*\(\s*(MAXDOP|RECOMPILE|HASH|LOOP|MERGE|FORCE)"),
    ("top", r"\bTOP\s*\(?\s*[\d@]"),
    ("top_with_ties", r"\bTOP\s*\(?[^)]*\)?\s+WITH\s+TIES\b"),
    ("cross_apply", r"\b(CROSS|OUTER)\s+APPLY\b"),
    ("pivot", r"\b(PIVOT|UNPIVOT)\s*\("),
    ("string_agg", r"\bSTRING_AGG\s*\("),
    ("for_xml_json", r"\bFOR\s+(XML|JSON)\b"),
    ("openjson_xml", r"\b(OPENJSON|OPENXML|\.value\(|\.query\(|\.nodes\()\b"),
    ("linked_server", r"\b(OPENQUERY|OPENROWSET|OPENDATASOURCE)\s*\(|\b\w+\.\w+\.\w+\.\w+\b"),
    ("cross_database", r"\b[\[\w\]]+\.\[?dbo\]?\.[\[\w\]]+\b"),
    ("clr_or_xp", r"\b(xp_\w+|sp_OA\w+)\b|\bEXTERNAL\s+NAME\b"),
    ("spatial", r"\b(GEOGRAPHY|GEOMETRY)\b|\.ST\w+\(|::STGeomFromText|::Point\("),
    ("hierarchyid", r"\bHIERARCHYID\b"),
    ("rowversion", r"\b(ROWVERSION|TIMESTAMP)\s*(,|NOT|NULL|\))"),
    ("sql_variant", r"\bSQL_VARIANT\b"),
    ("security_identity", r"\b(ORIGINAL_LOGIN|SUSER_SNAME|SUSER_NAME|SYSTEM_USER|SESSION_USER|USER_NAME|CURRENT_USER|IS_MEMBER|IS_ROLEMEMBER|HAS_PERMS_BY_NAME|SESSION_CONTEXT|CONTEXT_INFO)\s*\("),
    ("execute_as", r"\bEXECUTE\s+AS\b"),
    ("masking", r"\bMASKED\s+WITH\b"),
    ("rls_predicate", r"\bCREATE\s+SECURITY\s+POLICY\b|\bFILTER\s+PREDICATE\b"),
    ("nested_transaction_savepoint", r"\bSAVE\s+TRAN(SACTION)?\b"),
    ("goto", r"\bGOTO\s+\w+"),
    ("waitfor", r"\bWAITFOR\b"),
    ("service_broker_mail", r"\b(sp_send_dbmail|SEND\s+ON\s+CONVERSATION)\b"),
    ("sequence", r"\bNEXT\s+VALUE\s+FOR\b"),
    ("newid", r"\bNEWID\s*\(\)|\bNEWSEQUENTIALID\s*\(\)"),
    ("getdate", r"\b(GETDATE|GETUTCDATE|SYSDATETIME|SYSUTCDATETIME|SYSDATETIMEOFFSET)\s*\(\)"),
    ("date_functions", r"\b(DATEADD|DATEDIFF|DATEPART|DATENAME|EOMONTH|DATEFROMPARTS|CONVERT)\s*\("),
    ("string_functions", r"\b(ISNULL|LEN|CHARINDEX|PATINDEX|STUFF|IIF|QUOTENAME|FORMAT|REPLICATE)\s*\("),
    ("bracket_identifiers", r"\[[A-Za-z_][\w ]*\]"),
    ("nvarchar_literal", r"(?<![\w'])N'"),
    ("plus_concat", r"'\s*\+\s*|\+\s*'|\+\s*N'"),
    ("multiple_result_sets", r"\bSELECT\b[\s\S]+?\bSELECT\b"),
    ("cdc_watermark", r"\b(LastUpdated\w*|Modified\w*|Updated\w*|ChangeTracking|CHANGETABLE|__\$operation)\b\s*(>|>=|<|<=|BETWEEN)"),
    ("update_from_join", r"\bUPDATE\s+\w+\s+SET\b[\s\S]{0,300}\bFROM\b[\s\S]{0,200}\bJOIN\b"),
    ("delete_with_join", r"\bDELETE\s+\w+\s+FROM\b[\s\S]{0,200}\bJOIN\b"),
    ("insert_select", r"\bINSERT\s+INTO\b[\s\S]{0,300}\bSELECT\b"),
    ("truncate", r"\bTRUNCATE\s+TABLE\b"),
    ("bulk_insert", r"\bBULK\s+INSERT\b"),
]
INVENTORY_RES = [(n, re.compile(p, re.I)) for n, p in INVENTORY_RULES]

# for placement/complexity scoring
HEAVY = {"recursive_cte", "merge", "dynamic_sql", "cursor", "while_loop", "pivot", "cross_apply", "spatial", "clr_or_xp",
         "linked_server", "table_valued_param", "global_temp_table", "for_xml_json", "openjson_xml", "hierarchyid", "goto"}
SECURITY = {"security_identity", "execute_as", "masking", "rls_predicate"}


def inventory(sql: str) -> dict:
    """Construct inventory of a T-SQL text: {construct: count} plus derived facts (comments and string
    literals are ignored so that a mention in a comment does not count)."""
    code = strip_comments(sql)
    code_nolit = re.sub(r"N?'(?:[^']|'')*'", "''", code)
    counts = {}
    for name, rx in INVENTORY_RES:
        target = code if name in ("nvarchar_literal", "plus_concat") else code_nolit
        n = len(rx.findall(target))
        if name == "multiple_result_sets":
            # count SELECT statements that return rows to the client inside a procedure body (approximation:
            # top-level SELECT not followed by INTO/@assignment and not inside an INSERT/EXISTS/CTE)
            n = _count_result_selects(code_nolit)
        if n:
            counts[name] = n
    stmts = len([s for s in re.split(r";|\bGO\b", code_nolit, flags=re.I) if s.strip()])
    lines = len([l for l in sql.splitlines() if l.strip()])
    out = {"constructs": counts, "statements": stmts, "lines": lines,
           "heavy": sorted(c for c in counts if c in HEAVY), "security": sorted(c for c in counts if c in SECURITY),
           "object_type": _object_type(counts)}
    return out


def _count_result_selects(code: str) -> int:
    n = 0
    for m in re.finditer(r"\bSELECT\b", code, re.I):
        before = code[max(0, m.start() - 60):m.start()].upper()
        after = code[m.end():m.end() + 400]
        if re.search(r"\b(INSERT\s+INTO\s+[\[\]\w.#]+\s*(\([^)]*\))?\s*|EXISTS\s*\(|IN\s*\(|AS\s*\(|=\s*\(|\(\s*)$", before, re.I):
            continue
        if re.match(r"\s+(@\w+\s*=|.*?\bINTO\s+[#@\[\w])", after, re.I | re.S):
            continue
        n += 1
    return n


def _object_type(counts: dict) -> str:
    for k in ("trigger", "procedure", "function", "view", "table_ddl"):
        if counts.get(k):
            return {"table_ddl": "TABLE", "procedure": "PROCEDURE", "function": "FUNCTION", "view": "VIEW", "trigger": "TRIGGER"}[k]
    return "ETL_SQL"


REF_RE = re.compile(r"\b(?:FROM|JOIN|INTO|UPDATE|DELETE\s+FROM|MERGE\s+INTO|MERGE|EXEC(?:UTE)?|TRUNCATE\s+TABLE|APPLY)\s+((?:\[[^\]]+\]|\w+)(?:\s*\.\s*(?:\[[^\]]+\]|\w+)){0,3})", re.I)
DEFINED_RE = re.compile(r"\bCREATE\s+(?:OR\s+ALTER\s+)?(?:PROC(?:EDURE)?|FUNCTION|VIEW|TRIGGER|TABLE)\s+((?:\[[^\]]+\]|\w+)(?:\s*\.\s*(?:\[[^\]]+\]|\w+)){0,2})", re.I)
SQL_KEYWORDS = {"select", "values", "dual", "where", "on", "set", "with", "as", "openjson", "string_split", "unnest", "generate_series", "sys", "information_schema"}


def references(sql: str) -> dict:
    """{'defines': [schema.name...], 'reads_writes': [schema.name...], 'temp': [#t...], 'unresolved': [...]}"""
    code = re.sub(r"N?'(?:[^']|'')*'", "''", strip_comments(sql))
    defines = []
    for m in DEFINED_RE.finditer(code):
        s, n = split_qualified(re.sub(r"\s+", "", m.group(1)))
        defines.append(f"{s or 'dbo'}.{n}")
    refs, temp, unresolved = set(), set(), set()
    aliases = {a.lower() for a in re.findall(r"\b(?:FROM|JOIN|UPDATE|INTO)\s+(?:\[[^\]]+\]|\w+)(?:\s*\.\s*(?:\[[^\]]+\]|\w+))*\s+(?:AS\s+)?(\w+)\b", code, re.I)}
    aliases -= {"on", "where", "set", "values", "select", "with", "as", "inner", "left", "right", "full", "cross", "outer", "join", "group", "order", "having", "union", "output", "into", "tablesample", "nolock"}
    cursors = {c.lower() for c in re.findall(r"\bDECLARE\s+(\w+)\s+(?:\w+\s+)*CURSOR\b", code, re.I)}
    for m in REF_RE.finditer(code):
        raw = re.sub(r"\s+", "", m.group(1))
        if raw.startswith("#"):
            temp.add(raw); continue
        if raw.startswith("@") or raw.lower() in SQL_KEYWORDS or raw.lower().startswith(("sys.", "information_schema.")):
            continue
        parts = raw.count(".")
        if parts >= 3:
            unresolved.add(raw + " (four-part name / linked server)"); continue
        s, n = split_qualified(raw)
        if n.lower() in SQL_KEYWORDS or not n:
            continue
        if s is None and (n.lower() in cursors or n.lower() in aliases or n.lower().startswith(("sp_", "xp_", "fn_"))):
            continue
        key = f"{s or 'dbo'}.{n}"
        if key not in defines:
            refs.add(key)
    # CTE names are not tables
    ctes = {unquote(x).lower() for x in re.findall(r"\b(?:WITH|,)\s*([\[\w\]]+)\s*(?:\([^)]*\))?\s*AS\s*\(", code, re.I)}
    refs = {r for r in refs if r.split(".")[-1].lower() not in ctes}
    return {"defines": defines, "reads_writes": sorted(refs), "temp": sorted(temp), "unresolved": sorted(unresolved)}
