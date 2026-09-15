<#
.SYNOPSIS
  informatica-etl-conversion skill — self-test (Windows version of run_skill_tests.sh).
.DESCRIPTION
  1. Python unit tests for infa_sql_tool.py and the worked examples
  2. re-generates each example's .postgres.xml from its converted SQL and checks it is identical to the
     committed file; static checks; renders the SQL
  3. runs the rendered SQL + assertions on a PostgreSQL 15+ TEST database
  4. checks every corner case IC-nn has a tagged test
#>
$ErrorActionPreference = 'Continue'
$Scripts = $PSScriptRoot
$Skill = Split-Path -Parent $Scripts
$Engine = Join-Path $Scripts '..\..\sql-conversion\scripts'
$Ex = Join-Path $Skill 'references\examples'
$Tool = Join-Path $Scripts 'infa_sql_tool.py'
if (-not (Test-Path (Join-Path $Engine 'pgtest.ps1'))) { Write-Error "shared test engine not found at $Engine (install the sql-conversion skill)"; exit 2 }
. (Join-Path $Engine 'winlib.ps1')
$env:MIGRATION_LINEAGE = '0'     # regenerating the committed examples verifies them; it is not a migration
$Results = [IO.Path]::GetTempFileName(); $SqlRes = [IO.Path]::GetTempFileName()
$TmpX = Join-Path ([IO.Path]::GetTempPath()) ("infa-xml-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $TmpX | Out-Null
try {
    Write-Host '################ 1. tool unit tests ################'
    Invoke-MigPython -ArgList @((Join-Path $Scripts 'tests\test_infa_tool.py'), '--results', $Results); $py = $LASTEXITCODE

    Write-Host '################ 2. regenerate, check, render examples ################'
    $gen = 0
    New-Item -ItemType Directory -Force -Path (Join-Path $Scripts '.generated') | Out-Null
    foreach ($n in @('01_orders_incremental', '02_customer_dim', '03_shipping_procs', '04_product_sales_session_override', '05_customer_summary_real_export')) {
        $out = Join-Path $TmpX "$n.postgres.xml"
        Invoke-MigPython -ArgList @($Tool, 'inject', (Join-Path $Ex "$n.sqlserver.xml"), (Join-Path $Ex "$n.sql"), $out, '--map', (Join-Path $Ex 'params\pg_map.json')) | Out-Null
        $committed = Join-Path $Ex "$n.postgres.xml"
        if (-not (Test-Path $out) -or (Get-FileHash $out).Hash -ne (Get-FileHash $committed).Hash) {
            Write-Host "FAIL  $n.postgres.xml is out of date - regenerate with: infa_sql_tool.py inject ... --map params\pg_map.json"; $gen = 1
        }
        $last = Invoke-MigPython -ArgList @($Tool, 'check', (Join-Path $Ex "$n.sql"), '--source-dir', (Join-Path $Ex "$n.sql"), '--xml', $committed) | Select-Object -Last 1
        Write-Host "  ${n}: $last"
        Invoke-MigPython -ArgList @($Tool, 'render', (Join-Path $Ex "$n.sql"), (Join-Path $Scripts ".generated\$n.rendered.sql"),
            '--params', (Join-Path $Ex 'params\etl_params.prm'), '--bindings', (Join-Path $Ex 'params\test_bindings.json'), '--prefix', ("ex" + $n.Substring(0, 2) + "_")) | Out-Null
    }

    Write-Host '################ 3. PostgreSQL tests ################'
    & (Join-Path $Engine 'pgtest.ps1') (Join-Path $Scripts 'selftest.sql') -Results $SqlRes
    $rc = $LASTEXITCODE
    if ($rc -eq 2) { exit 2 }
    Get-Content -LiteralPath $SqlRes -Encoding UTF8 | Add-Content -LiteralPath $Results -Encoding UTF8

    Write-Host '################ 4. corner-case coverage ################'
    Invoke-MigPython -ArgList @((Join-Path $Engine 'check_rule_coverage.py'), '--results', $Results, '--no-steering',
        '--catalog', (Join-Path $Skill 'references\corner-cases.md'), '--prefix', 'IC'); $cov = $LASTEXITCODE
    if ($py -eq 0 -and $gen -eq 0 -and $rc -eq 0 -and $cov -eq 0) { Write-Host 'SKILL SELF-TEST: PASS'; exit 0 }
    [Console]::Error.WriteLine("SKILL SELF-TEST: FAIL (unit $py, regenerate $gen, sql $rc, coverage $cov)")
    exit 1
} finally {
    Remove-Item -LiteralPath $Results, $SqlRes -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $TmpX -Recurse -Force -ErrorAction SilentlyContinue
}
