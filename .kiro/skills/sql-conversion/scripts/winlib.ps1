# ============================================================
# Shared helpers for the Windows (PowerShell 5.1+ / PowerShell 7) versions of the kit's scripts.
# Dot-source it:  . (Join-Path $PSScriptRoot 'winlib.ps1')
# ============================================================
$env:PYTHONUTF8 = '1'                                   # Python reads/writes UTF-8 regardless of the ANSI code page
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }
$script:MigPython = $null

function Get-MigPython {
    # python.exe / python3.exe / py -3 — verified to run (the Microsoft Store alias stub does not)
    if ($null -ne $script:MigPython) { return $script:MigPython }
    foreach ($name in @('python', 'python3', 'py')) {
        $cmd = Get-Command $name -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($null -eq $cmd) { continue }
        $prefix = @()
        if ($name -eq 'py') { $prefix = @('-3') }
        & $cmd.Source @($prefix + @('-c', 'import sys; sys.exit(0 if sys.version_info >= (3, 9) else 1)')) *> $null
        if ($LASTEXITCODE -eq 0) {
            $script:MigPython = [pscustomobject]@{ Exe = $cmd.Source; Prefix = $prefix }
            return $script:MigPython
        }
    }
    throw 'Python 3.9+ not found. Install it from python.org and tick "Add python.exe to PATH".'
}

function Invoke-MigPython {
    # Runs Python with an explicit argument array; the exit code is in $LASTEXITCODE.
    param([string[]] $ArgList)
    $py = Get-MigPython
    & $py.Exe @($py.Prefix + $ArgList)
}

function Find-MigPsql {
    $cmd = Get-Command psql -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -ne $cmd) { return $cmd.Source }
    $roots = @($env:ProgramFiles, ${env:ProgramFiles(x86)}) | Where-Object { $_ }
    foreach ($root in $roots) {
        $found = Get-ChildItem -Path (Join-Path $root 'PostgreSQL\*\bin\psql.exe') -ErrorAction SilentlyContinue |
                 Sort-Object { [int]($_.Directory.Parent.Name -replace '\D', '') } -Descending | Select-Object -First 1
        if ($null -ne $found) { return $found.FullName }
    }
    return $null
}

function Write-MigAudit {
    # audit.py emit --service <Service> <ArgList...>; never fails the caller
    param([string] $KitDir, [string] $Service, [string[]] $ArgList)
    try { Invoke-MigPython -ArgList (@((Join-Path $KitDir 'audit.py'), 'emit', '--service', $Service) + $ArgList) *> $null } catch { }
}

function Read-MigEnvFile {
    # KEY=VALUE lines (bash-compatible .env without expansions) -> hashtable
    param([string] $Path)
    $h = @{}
    foreach ($line in Get-Content -LiteralPath $Path -Encoding UTF8) {
        $t = $line.Trim()
        if ($t -eq '' -or $t.StartsWith('#') -or $t.IndexOf('=') -lt 1) { continue }
        $k = $t.Substring(0, $t.IndexOf('=')).Trim()
        $v = $t.Substring($t.IndexOf('=') + 1).Trim().Trim('"').Trim("'")
        $h[$k] = $v
    }
    return $h
}

function Get-MigEnv {
    param([string] $Name, [string] $Default = '')
    $v = [Environment]::GetEnvironmentVariable($Name)
    if ([string]::IsNullOrEmpty($v)) { return $Default }
    return $v
}
