<#
.SYNOPSIS
  Verify the Kiro agents (Windows version of verify_agents.sh): structural tests, kiro-cli validate/list, optional --Smoke headless prompts.
#>
param([switch]$Smoke)
$ErrorActionPreference = 'Continue'
$ProjectDir = Split-Path -Parent $PSScriptRoot
Set-Location $ProjectDir
if (-not (Test-Path (Join-Path $ProjectDir '.kiro'))) { Write-Error '.kiro\ not found - run from the project'; exit 2 }
$Engine = Join-Path $ProjectDir '.kiro\skills\sql-conversion\scripts'
. (Join-Path $Engine 'winlib.ps1')
$Res = [IO.Path]::GetTempFileName(); $rc = 0
try {
    Write-Host '################ 1. agent structural tests ################'
    Invoke-MigPython -ArgList @((Join-Path $ProjectDir '.kiro\agents\hooks\tests\test_agents.py'), '--results', $Res); if ($LASTEXITCODE -ne 0) { $rc = 1 }
    Invoke-MigPython -ArgList @((Join-Path $Engine 'check_rule_coverage.py'), '--results', $Res, '--no-steering', '--catalog', (Join-Path $ProjectDir '.kiro\agents\AGENTS.md'), '--prefix', 'AG'); if ($LASTEXITCODE -ne 0) { $rc = 1 }
    Write-Host '################ 2. kiro-cli ################'
    if (Get-Command kiro-cli -ErrorAction SilentlyContinue) {
        foreach ($f in @('sql-migration-agent', 'sql-reporting-agent', 'sql-migration-agent-windows', 'sql-reporting-agent-windows')) {
            & kiro-cli agent validate --path ".kiro\agents\$f.json"
            if ($LASTEXITCODE -eq 0) { Write-Host "valid: $f" } else { Write-Host "INVALID: $f"; $rc = 1 }
        }
        $listed = @(& kiro-cli agent list 2>&1 | ForEach-Object { $_ -replace "\x1b\[[0-9;]*m", '' } | Select-String -Pattern '^\s*sql-(migration|reporting)-agent(-windows)?\s+Workspace')
        if ($listed.Count -ge 4) { Write-Host "listed as Workspace agents: $($listed.Count)" } else { Write-Host "agents not all listed as Workspace agents ($($listed.Count)/4) - run inside the trusted project"; $rc = 1 }
    } else { Write-Host 'kiro-cli not installed: skipped validate/list (install Kiro CLI to run the agents)' }
    if ($Smoke) {
        Write-Host '################ 3. headless smoke prompts (read-only) ################'
        & kiro-cli chat --no-interactive --trust-tools=fs_read --agent sql-migration-agent-windows 'List the intake questions you would ask before converting source/schema/sales_db_schema.sql to Redshift. Do not run tools.' | Select-Object -Last 20; $s1 = $LASTEXITCODE
        & kiro-cli chat --no-interactive --trust-tools=fs_read --agent sql-reporting-agent-windows "Which pattern (RP-nn) and dialect rules (RD-nn) apply to 'monthly revenue with gap filling on Athena'? Answer from the skill, do not run tools." | Select-Object -Last 20; $s2 = $LASTEXITCODE
        if ($s1 -ne 0 -or $s2 -ne 0) { Write-Host "smoke prompts failed ($s1/$s2)"; $rc = 1 }
    }
    if ($rc -eq 0) { Write-Host 'AGENTS: PASS'; exit 0 }
    [Console]::Error.WriteLine('AGENTS: FAIL'); exit 1
} finally { Remove-Item -LiteralPath $Res -ErrorAction SilentlyContinue }
