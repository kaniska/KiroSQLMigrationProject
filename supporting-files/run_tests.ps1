<#
.SYNOPSIS
  SQLMigrationProject — test entry point (Windows version of run_tests.sh).
.DESCRIPTION
  run_tests.cmd              project suites + the three skill self-tests + agent hook tests + rule coverage
  run_tests.cmd --project    project suites only (tests\test_runner.sql)
  run_tests.cmd --skill      skill self-tests + agent hook tests
  TEST_TARGET=rds (default) Aurora PostgreSQL via IAM auth, values from metadata\test_connection.env
  TEST_TARGET=local          local PostgreSQL (PGHOST/PGPORT/PGUSER/PGDATABASE honoured)
  One MIGRATION_RUN_ID covers the whole run; pending audit/lineage records are synced at the end.
#>
param(
    [switch] $Project,
    [switch] $Skill,
    [Parameter(ValueFromRemainingArguments = $true)] [string[]] $Rest
)
$ErrorActionPreference = 'Continue'
$ScriptDir = $PSScriptRoot
$ProjectDir = Split-Path -Parent $ScriptDir
if (-not (Test-Path -LiteralPath (Join-Path $ProjectDir '.kiro') -PathType Container)) {
    if (Test-Path -LiteralPath (Join-Path $ProjectDir 'kiro') -PathType Container) {
        [Console]::Error.WriteLine("ERROR: found 'kiro\' but no '.kiro\'. Kiro only loads a folder named exactly .kiro - rename it back: Rename-Item kiro .kiro")
    } else {
        [Console]::Error.WriteLine("ERROR: .kiro\ not found in $ProjectDir (steering, skills, agents and hooks live there)")
    }
    exit 2
}
$Engine = Join-Path $ProjectDir '.kiro\skills\sql-conversion\scripts'
$Kit = Join-Path $Engine 'migkit'
. (Join-Path $Engine 'winlib.ps1')

$Mode = 'all'
if ($Project -or ($Rest -contains '--project')) { $Mode = 'project' }
if ($Skill -or ($Rest -contains '--skill')) { $Mode = 'skill' }
foreach ($r in @($Rest)) { if ($r -and $r -notin @('--project', '--skill')) { Write-Error "usage: run_tests.cmd [--project|--skill]"; exit 2 } }

$runId = Invoke-MigPython -ArgList @((Join-Path $Kit 'audit.py'), 'current-run-id') | Select-Object -Last 1
$env:MIGRATION_RUN_ID = "$runId".Trim()

$cfg = Read-MigEnvFile (Join-Path $ProjectDir 'metadata\test_connection.env')
$target = Get-MigEnv 'TEST_TARGET' 'rds'
switch ($target) {
    'rds' {
        if (-not (Get-MigEnv 'PGHOST')) { $env:PGHOST = $cfg['RDS_PGHOST'] }
        if (-not (Get-MigEnv 'PGPORT')) { $env:PGPORT = $cfg['RDS_PGPORT'] }
        if (-not (Get-MigEnv 'PGDATABASE')) { $env:PGDATABASE = $cfg['RDS_PGDATABASE'] }
        if (-not (Get-MigEnv 'PGUSER')) { $env:PGUSER = $cfg['RDS_PGUSER'] }
        if (-not (Get-MigEnv 'AWS_REGION')) { $env:AWS_REGION = $cfg['RDS_AWS_REGION'] }
        $env:PG_IAM_AUTH = '1'
    }
    'local' {
        if (-not (Get-MigEnv 'PGHOST')) { $env:PGHOST = $cfg['LOCAL_PGHOST'] }
        if (-not (Get-MigEnv 'PGPORT')) { $env:PGPORT = $cfg['LOCAL_PGPORT'] }
        if (-not (Get-MigEnv 'PGDATABASE')) { $env:PGDATABASE = $cfg['LOCAL_PGDATABASE'] }
        if (-not (Get-MigEnv 'PGUSER')) { $env:PGUSER = $env:USERNAME }
        $env:PG_IAM_AUTH = '0'
        # a throw-away local cluster is usually reached as a superuser; Aurora runs refuse that
        if (-not (Get-MigEnv 'PGTEST_ALLOW_SUPERUSER')) { $env:PGTEST_ALLOW_SUPERUSER = '1' }
    }
    default { Write-Error "TEST_TARGET must be 'rds' or 'local'"; exit 2 }
}

Write-Host "Run id: $($env:MIGRATION_RUN_ID)   (troubleshoot: python $Kit\audit.py tail --run $($env:MIGRATION_RUN_ID.Substring(0, 8)))"
Write-MigAudit $Kit 'run_tests' @('--event', 'tests.run.start', '--attr', "mode=$Mode", '--attr', "target=$target", '--attr', "db.name=$($env:PGDATABASE)")
$projectRc = 0; $skillRc = 0; $hooksRc = 0
if ($Mode -ne 'skill') {
    Write-Host '################ PROJECT SUITES ################'
    & (Join-Path $Engine 'pgtest.ps1') (Join-Path $ProjectDir 'tests\test_runner.sql')
    $projectRc = $LASTEXITCODE
}
if ($Mode -ne 'project') {
    foreach ($s in @('sql-conversion', 'sql-reporting', 'informatica-etl-conversion', 'migration-assessment', 'sql-conversion-redshift', 'sql-conversion-iceberg', 'schema-conformance', 'schema-change-propagation')) {
        Write-Host "################ SKILL SELF-TEST: $s ################"
        & (Join-Path $ProjectDir ".kiro\skills\$s\scripts\run_skill_tests.ps1")
        $rc = $LASTEXITCODE
        if ($rc -ne 0) { $skillRc = $rc }
        if ($rc -eq 0) { Write-Host "Skill ${s}: PASS" } else { Write-Host "Skill ${s}: FAIL ($rc)" }
    }
    Write-Host '################ AGENT HOOKS: guardrails + audit ################'
    $hres = [IO.Path]::GetTempFileName()
    Invoke-MigPython -ArgList @((Join-Path $ProjectDir '.kiro\agents\hooks\tests\test_hooks.py'), '--results', $hres) 2>&1 | Select-Object -Last 3
    $hooksRc = $LASTEXITCODE
    Invoke-MigPython -ArgList @((Join-Path $Engine 'check_rule_coverage.py'), '--results', $hres, '--no-steering',
        '--catalog', (Join-Path $ProjectDir '.kiro\agents\hooks\GUARDRAILS.md'), '--prefix', 'GRD', '--prefix', 'HOOK')
    if ($LASTEXITCODE -ne 0) { $hooksRc = 1 }
    Remove-Item -LiteralPath $hres -ErrorAction SilentlyContinue
}

function Show-Status([int] $code) { if ($code -eq 0) { return 'PASS' } return "FAIL ($code)" }
Write-Host '=================================================='
if ($Mode -ne 'skill') { Write-Host "Project suites : $(Show-Status $projectRc)" }
if ($Mode -ne 'project') { Write-Host "Skill self-tests: $(Show-Status $skillRc)"; Write-Host "Agent hooks    : $(Show-Status $hooksRc)" }
Write-Host "Run id         : $($env:MIGRATION_RUN_ID)"
$sev = 'ERROR'
if ($projectRc -eq 0 -and $skillRc -eq 0 -and $hooksRc -eq 0) { $sev = 'INFO' }
Write-MigAudit $Kit 'run_tests' @('--event', 'tests.run.end', '--severity', $sev, '--attr', "project_rc=$projectRc", '--attr', "skill_rc=$skillRc", '--attr', "hooks_rc=$hooksRc")
Invoke-MigPython -ArgList @((Join-Path $Kit 'services.py'), 'sync') *> $null
if ($LASTEXITCODE -ne 0) { Write-Host "note: audit/lineage sync to AWS skipped (see: python $Kit\services.py status)" }
if ($sev -eq 'INFO') { Write-Host 'RESULT: PASS'; exit 0 }
[Console]::Error.WriteLine('RESULT: FAIL')
exit 1
