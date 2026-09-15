<#
.SYNOPSIS
  sql-conversion skill — generic PostgreSQL test runner (Windows version of pgtest.sh).
.DESCRIPTION
  Runs a psql test manifest (lib/guard_and_reset.sql -> schema -> seed -> test_framework.sql -> objects
  -> suites -> lib/report.sql). Same behaviour as pgtest.sh:
    * connection from the standard libpq variables PGHOST PGPORT PGDATABASE PGUSER PGPASSWORD PGSSLMODE;
      PG_IAM_AUTH=1 + AWS_REGION generates a 15-minute Aurora IAM token with the AWS CLI;
    * one run id (MIGRATION_RUN_ID) -> application_name mig:<manifest>:<run8>, setting migration.run_id;
    * security preflight of the manifest and every included file (exit 4 unless PGTEST_ALLOW_DANGEROUS=1);
    * superuser sessions refused unless PGTEST_ALLOW_SUPERUSER=1; PG_SECRET_FROM_SERVICES=1 reads the
      connection from AWS Secrets Manager via migkit\services.py; audit events pgtest.start / pgtest.end.
  Exit code: 0 all tests passed - 3 failures/errors - 2 setup problem - 4 refused by preflight.
.EXAMPLE
  powershell -NoProfile -ExecutionPolicy Bypass -File pgtest.ps1 selftest.sql -Results C:\Temp\results.txt
#>
param(
    [Parameter(Position = 0)] [string] $Manifest,
    [string] $Results = '',
    [Parameter(ValueFromRemainingArguments = $true)] [string[]] $Rest
)
$ErrorActionPreference = 'Continue'
. (Join-Path $PSScriptRoot 'winlib.ps1')
if ($Rest) { for ($i = 0; $i -lt $Rest.Count - 1; $i++) { if ($Rest[$i] -eq '--results') { $Results = $Rest[$i + 1] } } }
if ([string]::IsNullOrEmpty($Manifest)) { Write-Error 'usage: pgtest.ps1 <manifest.sql> [-Results FILE]'; exit 2 }
if (-not (Test-Path -LiteralPath $Manifest -PathType Leaf)) { Write-Error "manifest not found: $Manifest"; exit 2 }
$Manifest = (Resolve-Path -LiteralPath $Manifest).Path
$Kit = Join-Path $PSScriptRoot 'migkit'

# Credentials from AWS Secrets Manager (when configured): re-run once with them in the environment
if ((Get-MigEnv 'PG_SECRET_FROM_SERVICES') -eq '1' -and -not (Get-MigEnv '_PGTEST_SECRETS_LOADED')) {
    $env:_PGTEST_SECRETS_LOADED = '1'
    $child = @((Join-Path $Kit 'services.py'), 'exec', '--', 'powershell', '-NoProfile', '-ExecutionPolicy', 'Bypass',
               '-File', $PSCommandPath, $Manifest)
    if ($Results) { $child += @('-Results', $Results) }
    Invoke-MigPython -ArgList $child
    exit $LASTEXITCODE
}

$runId = (Invoke-MigPython -ArgList @((Join-Path $Kit 'audit.py'), 'current-run-id') | Select-Object -Last 1)
if ($runId) { $env:MIGRATION_RUN_ID = "$runId".Trim() }
$stem = [IO.Path]::GetFileNameWithoutExtension($Manifest)
if ($stem.Length -gt 40) { $stem = $stem.Substring(0, 40) }
if (-not (Get-MigEnv 'PGAPPNAME')) { $env:PGAPPNAME = "mig:${stem}:$($env:MIGRATION_RUN_ID.Substring(0, 8))" }
$opt = "-c migration.run_id=$($env:MIGRATION_RUN_ID)"
if (Get-MigEnv 'PGOPTIONS') { $env:PGOPTIONS = "$($env:PGOPTIONS) $opt" } else { $env:PGOPTIONS = $opt }

$psql = Find-MigPsql
if (-not $psql) { Write-Error 'psql not found (install PostgreSQL 17 client tools, e.g. from postgresql.org, and add its bin folder to PATH)'; exit 2 }
if (-not (Get-MigEnv 'PGDATABASE')) { Write-Error 'set PGDATABASE (a database whose name contains test/dev/sandbox/local)'; exit 2 }

if ((Get-MigEnv 'PG_IAM_AUTH') -eq '1') {
    foreach ($v in @('PGHOST', 'PGUSER', 'AWS_REGION')) { if (-not (Get-MigEnv $v)) { Write-Error "PG_IAM_AUTH=1 needs $v"; exit 2 } }
    if (-not (Get-Command aws -ErrorAction SilentlyContinue)) { Write-Error 'aws CLI not found (needed for IAM auth)'; exit 2 }
    $token = & aws rds generate-db-auth-token --hostname $env:PGHOST --port (Get-MigEnv 'PGPORT' '5432') --username $env:PGUSER --region $env:AWS_REGION
    if ($LASTEXITCODE -ne 0 -or -not $token) { Write-Error 'could not generate an IAM auth token (check AWS credentials)'; exit 2 }
    $env:PGPASSWORD = ($token | Out-String).Trim()
    if (-not (Get-MigEnv 'PGSSLMODE')) { $env:PGSSLMODE = 'require' }
}
if (-not (Get-MigEnv 'PGCONNECT_TIMEOUT')) { $env:PGCONNECT_TIMEOUT = '15' }

Write-Host "Run id:   $($env:MIGRATION_RUN_ID) (application_name $($env:PGAPPNAME))"
Invoke-MigPython -ArgList @((Join-Path $Kit 'security.py'), 'preflight', $Manifest)
if ($LASTEXITCODE -ne 0) {
    if ((Get-MigEnv 'PGTEST_ALLOW_DANGEROUS') -eq '1') {
        Write-Warning 'preflight findings overridden by PGTEST_ALLOW_DANGEROUS=1'
        Write-MigAudit $Kit 'pgtest' @('--event', 'pgtest.preflight_override', '--severity', 'WARN', '--attr', "manifest=$Manifest")
    } else {
        [Console]::Error.WriteLine('REFUSED: the manifest or an included file failed the security preflight (see above).')
        Write-MigAudit $Kit 'pgtest' @('--event', 'pgtest.refused', '--severity', 'ERROR', '--attr', "manifest=$Manifest", '--attr', 'reason=preflight')
        exit 4
    }
}
$dbUser = Get-MigEnv 'PGUSER' $env:USERNAME
$iam = ''
if ((Get-MigEnv 'PG_IAM_AUTH') -eq '1') { $iam = ' (IAM auth)' }
Write-Host "Manifest: $Manifest"
Write-Host "Target:   ${dbUser}@$(Get-MigEnv 'PGHOST' 'localhost'):$(Get-MigEnv 'PGPORT' '5432')/$($env:PGDATABASE)$iam"

$psqlArgs = @('-X', '-v', 'ON_ERROR_STOP=1', '-v', "run_id=$($env:MIGRATION_RUN_ID)")
if ($Results) { $psqlArgs += @('-v', "results_file=$($Results -replace '\\', '/')") }
if ((Get-MigEnv 'PGTEST_ALLOW_SUPERUSER') -eq '1') { $psqlArgs += @('-v', 'allow_superuser=1') }
$psqlArgs += @('-f', $Manifest)

$sha = (Get-FileHash -Algorithm SHA256 -LiteralPath $Manifest).Hash.ToLower()
Write-MigAudit $Kit 'pgtest' @('--event', 'pgtest.start', '--attr', "manifest=$Manifest", '--attr', "manifest_sha256=$sha",
    '--attr', "db.host=$(Get-MigEnv 'PGHOST' 'local')", '--attr', "db.name=$($env:PGDATABASE)", '--attr', "db.user=$dbUser",
    '--attr', "iam_auth=$(Get-MigEnv 'PG_IAM_AUTH' '0')", '--attr', "application_name=$($env:PGAPPNAME)")
$start = Get-Date
& $psql @psqlArgs
$rc = $LASTEXITCODE
$summary = ''
if ($Results -and (Test-Path -LiteralPath $Results)) {
    $c = @{ PASS = 0; FAIL = 0; ERROR = 0 }
    foreach ($l in Get-Content -LiteralPath $Results -Encoding UTF8) { $s = ($l -split "`t")[0]; if ($c.ContainsKey($s)) { $c[$s]++ } }
    $summary = "pass=$($c.PASS) fail=$($c.FAIL) error=$($c.ERROR)"
}
$sev = 'ERROR'
if ($rc -eq 0) { $sev = 'INFO' }
Write-MigAudit $Kit 'pgtest' @('--event', 'pgtest.end', '--severity', $sev, '--attr', "manifest=$Manifest", '--attr', "exit_code=$rc",
    '--attr', "duration_s=$([int]((Get-Date) - $start).TotalSeconds)", '--attr', "results=$summary")
if ($rc -eq 0) { Write-Host "RESULT: PASS (run $($env:MIGRATION_RUN_ID))" } else { [Console]::Error.WriteLine("RESULT: FAIL (psql exit code $rc, run $($env:MIGRATION_RUN_ID))") }
exit $rc
