#Requires -Version 7.0
<#
.SYNOPSIS
Destroys the RunPod network volume created by scripts/session-up.ps1.

.DESCRIPTION
Detach the volume from your endpoint first:
  Endpoint -> Manage -> Edit Endpoint -> Advanced -> Network Volumes
Then run this script. It asks you to type 'destroy' unless -Force is given.
Destruction permanently deletes every model on the volume and stops the
hourly storage billing.

.PARAMETER EnvFile
Env file to load (default: the repo-root .env).

.PARAMETER Force
Skip the interactive confirmation (for automation).

.PARAMETER DryRun
Print the commands without executing them.

.EXAMPLE
pwsh -File scripts/session-down.ps1
pwsh -File scripts/session-down.ps1 -DryRun
#>
[CmdletBinding()]
param(
    [string]$EnvFile = '',
    [switch]$Force,
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

if (-not (Get-Command terraform -ErrorAction SilentlyContinue)) {
    throw 'terraform not found on PATH. Install Terraform >= 1.5 and retry.'
}

if (-not $DryRun -and -not $env:RUNPOD_API_KEY) {
    throw 'RUNPOD_API_KEY is not set. Add it to the repo-root .env (copy .env.example) or export it.'
}

$volumeId = $null
if (Test-Path (Join-Path $infraDir '.terraform')) {
    $volumeId = & terraform "-chdir=$infraDir" output -raw volume_id 2>$null
    if ($LASTEXITCODE -ne 0) {
        $volumeId = $null
    }
}

if ([string]::IsNullOrWhiteSpace($volumeId)) {
    Write-Host 'No volume id found in the Terraform state; nothing to destroy.'
    Write-Host 'If a volume still exists in the console, reconcile the state first:'
    Write-Host '  terraform -chdir=infra state rm runpod_network_volume.models   # if it is already gone'
    Write-Host '  terraform -chdir=infra import runpod_network_volume.models <volume-id>  # to adopt it'
    exit 0
}

Write-Host "Volume in state: $volumeId"
Write-Host 'Detach it from the endpoint first (Advanced -> Network Volumes -> deselect -> Save).'
Write-Host 'Deleting the volume permanently removes all models on it.'

if (-not $Force -and -not $DryRun) {
    $answer = Read-Host "Type 'destroy' to confirm"
    if ($answer -ne 'destroy') {
        Write-Host 'Aborted; nothing was deleted.'
        exit 1
    }
}

$terraformArgs = @('destroy', '-auto-approve')
$display = 'terraform -chdir="' + $infraDir + '" ' + ($terraformArgs -join ' ')

if ($DryRun) {
    Write-Host "[dry-run] $display"
    exit 0
}

& terraform "-chdir=$infraDir" @terraformArgs
if ($LASTEXITCODE -ne 0) {
    Write-Host ''
    Write-Host 'Destroy failed. If the volume was already deleted in the console, remove it from state:'
    Write-Host '  terraform -chdir=infra state rm runpod_network_volume.models'
    exit $LASTEXITCODE
}

Write-Host ''
Write-Host 'Volume destroyed; storage billing has stopped.'
