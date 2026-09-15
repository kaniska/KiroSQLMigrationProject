<#
.SYNOPSIS
  Headless batch migration with Kiro CLI and the sql-migration agent (Windows version of kiro_migrate.sh).
.DESCRIPTION
  kiro_migrate.cmd                          every source file not yet in the migration log
  kiro_migrate.cmd source\usp_A.sql ...     just these files
  Each file is scanned first (prompt injection, hidden characters, credentials) and skipped when flagged
  unless ALLOW_FLAGGED_INPUTS=1. The agent converts, adds tests, updates metadata\migration_log.json and runs
  the project tests; a full test run closes the batch, converted files are archived and evidence synced.
  One batch run id (MIGRATION_RUN_ID) for everything. TRUST_TOOLS=1 adds --trust-tools (the guard hook
  still applies). Agent: sql-migration-agent-windows (AGENT overrides). Headless runs may need KIRO_API_KEY.
#>
param([Parameter(ValueFromRemainingArguments = $true)] [string[]] $Files)
$ErrorActionPreference = 'Continue'
$ProjectDir = Split-Path -Parent $PSScriptRoot
if (-not (Test-Path -LiteralPath (Join-Path $ProjectDir '.kiro') -PathType Container)) {
    if (Test-Path -LiteralPath (Join-Path $ProjectDir 'kiro') -PathType Container) {
        [Console]::Error.WriteLine("ERROR: found 'kiro\' but no '.kiro\'. Kiro only loads a folder named exactly .kiro - rename it back: Rename-Item kiro .kiro")
    } else {
        [Console]::Error.WriteLine("ERROR: .kiro\ not found in $ProjectDir (steering, skills, agents and hooks live there)")
    }
    exit 2
}
Set-Location -LiteralPath $ProjectDir
$Engine = Join-Path $ProjectDir '.kiro\skills\sql-conversion\scripts'
$Kit = Join-Path $Engine 'migkit'
. (Join-Path $Engine 'winlib.ps1')
if (-not (Get-Command kiro-cli -ErrorAction SilentlyContinue)) { Write-Error 'kiro-cli not found (https://kiro.dev/docs/cli)'; exit 2 }
New-Item -ItemType Directory -Force -Path 'logs' | Out-Null
$agent = Get-MigEnv 'AGENT' 'sql-migration-agent-windows'

$runId = Invoke-MigPython -ArgList @((Join-Path $Kit 'audit.py'), 'current-run-id') | Select-Object -Last 1
$env:MIGRATION_RUN_ID = "$runId".Trim()
Write-Host "Batch run id: $($env:MIGRATION_RUN_ID)"

if (-not $Files -or $Files.Count -eq 0) {
    $log = Get-Content -LiteralPath 'metadata\migration_log.json' -Raw -Encoding UTF8 | ConvertFrom-Json
    $done = @{}
    foreach ($f in $log.files) { if ($f.source_file) { $done[$f.source_file] = $true } }
    $Files = @(Get-ChildItem -Path 'source\*.sql' -File | Sort-Object Name | ForEach-Object { "source/$($_.Name)" } | Where-Object { -not $done.ContainsKey($_) })
}
if ($Files.Count -eq 0) { Write-Host 'Nothing pending - every source file is in metadata\migration_log.json.'; exit 0 }

$trust = @()
if ((Get-MigEnv 'TRUST_TOOLS') -eq '1') { $trust = @('--trust-tools=fs_read,fs_write,execute_bash') }
$failed = @(); $skipped = @()
Write-MigAudit $Kit 'kiro_migrate' @('--event', 'batch.start', '--attr', "files=$($Files.Count)", '--attr', "trust_tools=$(Get-MigEnv 'TRUST_TOOLS' '0')")
foreach ($f in $Files) {
    $name = [IO.Path]::GetFileNameWithoutExtension($f)
    Invoke-MigPython -ArgList @((Join-Path $Kit 'security.py'), 'scan', $f, '--fail-on', 'high') 2>&1 | Out-File -Encoding utf8 -FilePath "logs\$name.security.txt"
    if ($LASTEXITCODE -ne 0) {
        if ((Get-MigEnv 'ALLOW_FLAGGED_INPUTS') -ne '1') {
            Write-Host "!! $f skipped: security findings (see logs\$name.security.txt; ALLOW_FLAGGED_INPUTS=1 to convert anyway)"
            Write-MigAudit $Kit 'kiro_migrate' @('--event', 'batch.file_skipped', '--severity', 'WARN', '--attr', "file=$f", '--attr', 'reason=security_findings')
            $skipped += $f; continue
        }
        Write-Host "!! $f has security findings - converting because ALLOW_FLAGGED_INPUTS=1 (the agent is told to treat them as data)"
    }
    Write-MigAudit $Kit 'kiro_migrate' @('--event', 'batch.file_start', '--attr', "file=$f")
    Write-Host ">> $f  (log: logs\$name.log)"
    $prompt = "Convert $f to PostgreSQL following the sql-conversion skill (Steps 1-10). Register the converted file in tests/test_runner.sql, add tagged suites to tests/test_cases.sql, update metadata/migration_log.json, run 'supporting-files\run_tests.cmd --project' until it prints RESULT: PASS, then give the report."
    & kiro-cli chat --no-interactive --agent $agent @trust $prompt 2>&1 | Out-File -Encoding utf8 -FilePath "logs\$name.log"
    if ($LASTEXITCODE -ne 0) { Write-Host "   kiro-cli exited non-zero - see logs\$name.log"; $failed += $f }
}

Write-Host '== Final verification =='
& (Join-Path $PSScriptRoot 'run_tests.ps1')
$rc = $LASTEXITCODE
Invoke-MigPython -ArgList @((Join-Path $Kit 'services.py'), 'archive', 'generated', 'metadata/migration_log.json', '--label', 'batch') *> $null
Invoke-MigPython -ArgList @((Join-Path $Kit 'services.py'), 'sync') *> $null
$sev = 'ERROR'
if ($rc -eq 0 -and $failed.Count -eq 0) { $sev = 'INFO' }
Write-MigAudit $Kit 'kiro_migrate' @('--event', 'batch.end', '--severity', $sev, '--attr', "tests_rc=$rc", '--attr', "failed=$($failed.Count)", '--attr', "skipped=$($skipped.Count)")
if ($failed.Count -gt 0) { Write-Host "Files needing attention: $($failed -join ' ')" }
if ($skipped.Count -gt 0) { Write-Host "Files skipped by the security scan: $($skipped -join ' ')" }
Write-Host "Audit trail: python $Kit\audit.py tail --run $($env:MIGRATION_RUN_ID.Substring(0, 8))"
if ($rc -ne 0 -or $failed.Count -gt 0 -or $skipped.Count -gt 0) { exit 1 }
exit 0
