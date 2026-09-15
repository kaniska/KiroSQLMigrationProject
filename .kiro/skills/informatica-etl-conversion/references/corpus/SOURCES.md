# Real PowerCenter exports used as a regression corpus

These files are **unmodified** exports published by the U.S. Department of Health and Human
Services in [github.com/HHS/Informatica](https://github.com/HHS/Informatica) under the
**Unlicense** (public domain). They are Oracle-sourced, so they contain no SQL Server SQL. They
are kept here only to prove that `infa_sql_tool.py` reads the physical format of real
exports and writes an unchanged file back byte for byte. Test: `IC-T27`, rule `IC-39`.

| File | Source URL | Encoding | sha256 |
|---|---|---|---|
|  hhs/COMPTIME.xml  |  https://raw.githubusercontent.com/HHS/Informatica/master/XML/COMPTIME  | ISO-8859-1 |  317c5fb35eb4f2484b66f867b98250ea3fae58478a1d5583ac1568ed8c5221a4  |
|  hhs/Pay_Calendar.xml  |  https://raw.githubusercontent.com/HHS/Informatica/master/XML/Pay_Calendar  | ISO-8859-1 |  7070a04d9a67c8f3ba16776068dfd6f72802ad1666d9608b5234b052e7c2930e  |
|  hhs/EHRP2BIIS_UPDATE.xml  |  https://raw.githubusercontent.com/HHS/Informatica/master/XML/EHRP2BIIS_UPDATE  | ISO-8859-1 |  50446b58dc9f35c964e9ff7f5c65b6ad357d5574b8ea1094ad0250358879aa50  |

Real exports differ from hand-written examples in ways a naive parser breaks on:
- the XML declaration says `ISO-8859-1` or `Windows-1252`, not UTF-8;
- attributes are written `NAME ="Sql Query" VALUE ="…"` with a space before `=`;
- line breaks inside SQL are `&#xD;&#xA;`, tabs `&#x9;`, backslashes may be `&#x5c;`;
- lookups are `TYPE="Lookup Procedure"`; writer settings sit in `SESSIONEXTENSION`.

To test against more exports (for example your own repository exports, or the other public
repositories listed in `references/sql-locations.md`), put them in a folder and run
`INFA_CORPUS_DIR=<folder> python3 scripts/tests/test_infa_tool.py`. Check each repository's
licence before copying its files.
