<#
.SYNOPSIS
  Package the workspace (including the .kiro folder) as a zip (Windows version of package.sh).
.EXAMPLE
  supporting-files\package.cmd --out dist\SQLMigrationProject.zip
#>
param([Parameter(ValueFromRemainingArguments = $true)] [string[]] $PackArgs)
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
. (Join-Path $ProjectDir '.kiro\skills\sql-conversion\scripts\winlib.ps1')
Set-Location -LiteralPath $ProjectDir
Invoke-MigPython -ArgList (@((Join-Path $PSScriptRoot 'package.py')) + @($PackArgs | Where-Object { $_ }))
exit $LASTEXITCODE
