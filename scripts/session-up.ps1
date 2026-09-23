#Requires -Version 7.0
<#
.SYNOPSIS
Creates the RunPod network volume for the ComfyUI worker and prints the
attach + pre-warm steps.

.DESCRIPTION
Wraps `terraform apply` in infra/. After the volume exists, attach it to your
serverless endpoint:
  Endpoint -> Manage -> Edit Endpoint -> Advanced -> Network Volumes
Then pre-warm models (see docs/models.md -> Pre-warming) or let the first job
download them.

Network volumes are billed hourly while they exist ($0.07/GB/month for the
first 1 TB, standard tier). When you are done, detach the volume from the
endpoint and run scripts/session-down.ps1 to stop the charges.

.PARAMETER EnvFile
Env file to load (default: the repo-root .env).

.PARAMETER DryRun
Print the commands without executing them.

.EXAMPLE
pwsh -File scripts/session-up.ps1
pwsh -File scripts/session-up.ps1 -DryRun
#>
[CmdletBinding()]
param(
    [string]$EnvFile = '',
    [switch]$DryRun
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'env-common.ps1')

$repoRoot = Split-Path -Parent $PSScriptRoot
$infraDir = Join-Path $repoRoot 'infra'

$envPath = if ($EnvFile) { $EnvFile } else { Join-Path $repoRoot '.env' }
$loaded = Import-DotEnv -Path $envPath
if ($loaded -gt 0) {
    Write-Host "Loaded $loaded variable(s) from $envPath"
}

function Invoke-Terraform {
    param([string[]]$TerraformArgs)

    $display = 'terraform -chdir="' + $infraDir + '" ' + ($TerraformArgs -join ' ')
    if ($DryRun) {
        Write-Host "[dry-run] $display"
        return
    }
    & terraform "-chdir=$infraDir" @TerraformArgs
    if ($LASTEXITCODE -ne 0) {
        throw "terraform $($TerraformArgs[0]) failed (exit $LASTEXITCODE)"
    }
}

if (-not (Get-Command terraform -ErrorAction SilentlyContinue)) {
    throw 'terraform not found on PATH. Install Terraform >= 1.5 and retry.'
}

if (-not $DryRun -and -not $env:RUNPOD_API_KEY) {
    throw 'RUNPOD_API_KEY is not set. Add it to the repo-root .env (copy .env.example) or export it.'
}

if (-not (Test-Path (Join-Path $infraDir '.terraform'))) {
    Write-Host 'Initializing Terraform...'
    Invoke-Terraform @('init')
}

Write-Host 'Applying Terraform (creates the volume if it does not exist)...'
Invoke-Terraform @('apply', '-auto-approve')

if ($DryRun) {
    Write-Host '[dry-run] would run: terraform -chdir="infra" output -raw volume_id'
    exit 0
}

$volumeId = & terraform "-chdir=$infraDir" output -raw volume_id
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($volumeId)) {
    throw 'could not read volume_id from the Terraform state'
}

Write-Host ''
Write-Host "Volume id: $volumeId"
Write-Host ''
Write-Host 'Next steps:'
Write-Host '  1. Attach it to the endpoint:'
Write-Host '     https://www.console.runpod.io/serverless -> endpoint -> Manage -> Edit Endpoint'
Write-Host '     -> Advanced -> Network Volumes -> select this volume -> Save Endpoint.'
Write-Host '  2. Pre-warm models (recommended for large models) or send your first job:'
Write-Host '     see docs/models.md -> Pre-warming.'
Write-Host '  3. Run a job: python client/generate.py --set prompt="..." --set checkpoint=<file>.'
Write-Host ''
Write-Host 'When done: detach the volume from the endpoint, then run scripts/session-down.ps1.'
Write-Host 'Docs: docs/runpod-setup.md#10-session-lifecycle--teardown-ephemeral-volume'
