<#
.SYNOPSIS
  sql-reporting skill — self-test (Windows version of run_skill_tests.sh).
.DESCRIPTION
  Loads the sample schema + reporting fixtures + 15 example reports into a TEST database, runs the
  pattern and query-rule tests, and checks that every RQ-nn rule and RP-nn pattern has a tagged test.
  Needs the sql-conversion skill next to this one (shared test engine).
#>
$ErrorActionPreference = 'Continue'
$Scripts = $PSScriptRoot
$Engine = Join-Path $Scripts '..\..\sql-conversion\scripts'
if (-not (Test-Path (Join-Path $Engine 'pgtest.ps1'))) { Write-Error "shared test engine not found at $Engine (install the sql-conversion skill)"; exit 2 }
. (Join-Path $Engine 'winlib.ps1')
$Results = [IO.Path]::GetTempFileName()
try {
    & (Join-Path $Engine 'pgtest.ps1') (Join-Path $Scripts 'selftest.sql') -Results $Results
    $rc = $LASTEXITCODE
    if ($rc -eq 2) { exit 2 }
    Invoke-MigPython -ArgList @((Join-Path $Engine 'check_rule_coverage.py'), '--results', $Results, '--no-steering',
        '--catalog', (Join-Path $Scripts '..\references\patterns.md'), '--prefix', 'RQ', '--prefix', 'RP'); $cov = $LASTEXITCODE
    if ($rc -eq 0 -and $cov -eq 0) { Write-Host 'SKILL SELF-TEST: PASS'; exit 0 }
    [Console]::Error.WriteLine("SKILL SELF-TEST: FAIL (tests exit $rc, coverage exit $cov)")
    exit 1
} finally {
    Remove-Item -LiteralPath $Results -ErrorAction SilentlyContinue
}
