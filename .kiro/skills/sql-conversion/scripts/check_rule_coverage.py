#!/usr/bin/env python3
"""
sql-conversion skill — rule coverage check.

Reads the rule IDs defined in the skill's rule sources and verifies that
every one of them is exercised by at least one executed test:

  * [H<n>] hard rules and [P<n>] parity rules  →  .kiro/steering/migration.md
    (rules whose line contains "(process rule)" are exempt)
  * CC-<nn> corner cases                        →  references/corner-cases.md
    (rows whose Test column is "manual" are exempt)
  Other skills reuse it with their own ids:  --catalog <file> --prefix RQ --prefix RP
  --no-steering   (any "| <PREFIX>-nn |" table row is a rule; "manual" exempts it)

Executed tests come from the results file written by lib/report.sql
(pgtest.sh --results FILE): one line per test "STATUS<TAB>suite<TAB>name";
tags are the bracketed IDs in the test names, e.g. "[P4] [CC-43]".

Usage:
  check_rule_coverage.py --results FILE [--steering PATH] [--catalog PATH]
Exit code 0 = every rule covered, 1 = gaps (listed), 2 = input problem.
"""
import argparse
import pathlib
import re
import sys

for _s in (sys.stdout, sys.stderr):  # UTF-8 output on Windows pipes
    try:
        _s.reconfigure(encoding="utf-8", errors="replace")
    except (AttributeError, ValueError):
        pass

SKILL_DIR = pathlib.Path(__file__).resolve().parent.parent
DEFAULT_CATALOG = SKILL_DIR / "references" / "corner-cases.md"
DEFAULT_STEERING = SKILL_DIR.parent.parent / "steering" / "migration.md"

TAG = re.compile(r"\[(?:[^\]]*?)\]")
ID = re.compile(r"\b(H\d+|P\d+|[A-Z]{2,4}-\d+)\b")


def steering_rules(path: pathlib.Path):
    rules, exempt = set(), set()
    if not path.exists():
        return rules, exempt
    for line in path.read_text(encoding="utf-8").splitlines():
        for rid in re.findall(r"\[(H\d+|P\d+)\]", line):
            rules.add(rid)
            if "(process rule)" in line:
                exempt.add(rid)
    return rules, exempt


def catalog_rules(path: pathlib.Path, prefixes):
    rules, exempt = set(), set()
    pat = re.compile(r"\|\s*((?:%s)-\d+)\s*\|" % "|".join(re.escape(p) for p in prefixes))
    for line in path.read_text(encoding="utf-8").splitlines():
        m = pat.match(line)
        if not m:
            continue
        rules.add(m.group(1))
        cells = [c.strip().lower() for c in line.strip().strip("|").split("|")]
        if cells and cells[-1].startswith("manual"):
            exempt.add(m.group(1))
    return rules, exempt


def covered_ids(results: pathlib.Path):
    ids = set()
    for line in results.read_text(encoding="utf-8-sig").splitlines():
        parts = line.split("\t")
        if len(parts) < 3:
            continue
        for tag in TAG.findall(parts[2]):
            ids.update(ID.findall(tag))
    return ids


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--results", required=True, type=pathlib.Path)
    ap.add_argument("--steering", type=pathlib.Path, default=DEFAULT_STEERING)
    ap.add_argument("--catalog", type=pathlib.Path, default=DEFAULT_CATALOG)
    ap.add_argument("--prefix", action="append", help="rule id prefix in the catalog (default CC); repeatable")
    ap.add_argument("--no-steering", action="store_true", help="skip the [H]/[P] steering rules")
    a = ap.parse_args()
    prefixes = a.prefix or ["CC"]

    if not a.results.exists():
        print(f"ERROR: results file not found: {a.results}", file=sys.stderr)
        return 2
    if not a.catalog.exists():
        print(f"ERROR: corner-case catalog not found: {a.catalog}", file=sys.stderr)
        return 2

    s_rules, s_exempt = (set(), set()) if a.no_steering else steering_rules(a.steering)
    c_rules, c_exempt = catalog_rules(a.catalog, prefixes)
    covered = covered_ids(a.results)

    def report(label, rules, exempt):
        need = sorted(rules - exempt, key=lambda r: (r.rstrip("0123456789-"), int(re.sub(r"\D", "", r))))
        missing = [r for r in need if r not in covered]
        print(f"  {label:<28} {len(need) - len(missing):>3}/{len(need):<3} covered"
              + (f"   ({len(exempt)} exempt: {', '.join(sorted(exempt))})" if exempt else ""))
        return missing

    print("=== Rule coverage (tests tagged with rule IDs) ===")
    missing = []
    if not a.no_steering:
        if not s_rules:
            print(f"  steering file not found at {a.steering} — hard/parity rules not checked")
        missing += report("hard rules [H]", {r for r in s_rules if r.startswith("H")},
                          {r for r in s_exempt if r.startswith("H")})
        missing += report("parity rules [P]", {r for r in s_rules if r.startswith("P")},
                          {r for r in s_exempt if r.startswith("P")})
    for pre in prefixes:
        missing += report(f"catalog rules [{pre}]", {r for r in c_rules if r.startswith(pre + "-")},
                          {r for r in c_exempt if r.startswith(pre + "-")})
    unknown = sorted(i for i in covered if any(i.startswith(p + "-") for p in prefixes) and i not in c_rules)
    if unknown:
        print(f"  WARNING: tests reference unknown corner cases: {', '.join(unknown)}")
    if missing:
        print(f"COVERAGE: FAIL — no test for: {', '.join(missing)}")
        return 1
    print("COVERAGE: PASS")
    return 0


if __name__ == "__main__":
    sys.exit(main())
