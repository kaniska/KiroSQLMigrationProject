<#
.SYNOPSIS
  sql-conversion skill — self-test (Windows version of run_skill_tests.sh).
.DESCRIPTION
  1. loads the sample schema + every worked example into a TEST database and runs the static checks,
     example tests, corner-case tests and engine correlation tests (pgtest.ps1)
  2. checks that every hard rule, parity rule and corner case has a test
  3. migkit unit tests and coverage of references\security-logging.md (SEC/LOG/SVC)
  Connection: PG* variables; PG_IAM_AUTH=1 + AWS_REGION for Aurora IAM auth.
#>
$ErrorActionPreference = 'Continue'
$Scripts = $PSScriptRoot
. (Join-Path $Scripts 'winlib.ps1')
$Results = [IO.Path]::GetTempFileName()
try {
    & (Join-Path $Scripts 'pgtest.ps1') (Join-Path $Scripts 'selftest.sql') -Results $Results
    $rc = $LASTEXITCODE
    if ($rc -eq 2) { exit 2 }
    Write-Host '################ migkit: security, audit, AWS/local services ################'
    Invoke-MigPython -ArgList @((Join-Path $Scripts 'tests\test_migkit.py'), '--results', $Results); $kit = $LASTEXITCODE
    Invoke-MigPython -ArgList @((Join-Path $Scripts 'check_rule_coverage.py'), '--results', $Results); $cov = $LASTEXITCODE
    Invoke-MigPython -ArgList @((Join-Path $Scripts 'check_rule_coverage.py'), '--results', $Results, '--no-steering',
        '--catalog', (Join-Path $Scripts '..\references\security-logging.md'), '--prefix', 'SEC', '--prefix', 'LOG', '--prefix', 'SVC'); $seccov = $LASTEXITCODE
    Invoke-MigPython -ArgList @((Join-Path $Scripts 'check_rule_coverage.py'), '--results', $Results, '--no-steering', '--catalog', (Join-Path $Scripts '..\references\governance.md'), '--prefix', 'GOV'); if ($LASTEXITCODE -ne 0) { $seccov = 1 }
    if ($rc -eq 0 -and $cov -eq 0 -and $kit -eq 0 -and $seccov -eq 0) { Write-Host 'SKILL SELF-TEST: PASS'; exit 0 }
    [Console]::Error.WriteLine("SKILL SELF-TEST: FAIL (tests exit $rc, coverage exit $cov, migkit exit $kit, security coverage exit $seccov)")
    exit 1
} finally {
    Remove-Item -LiteralPath $Results -ErrorAction SilentlyContinue
}
