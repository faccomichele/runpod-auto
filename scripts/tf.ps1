#Requires -Version 7.0
<#
.SYNOPSIS
Runs terraform against infra/ with the repo-root .env loaded.

.DESCRIPTION
Wrapper so you do not have to export RUNPOD_API_KEY (and friends) by hand.
Every argument is forwarded to terraform, with -chdir=infra applied. Use
`-EnvFile <path>` to load a different env file.

.EXAMPLE
pwsh -File scripts/tf.ps1 plan
pwsh -File scripts/tf.ps1 apply -auto-approve
pwsh -File scripts/tf.ps1 output -raw volume_id
pwsh -File scripts/tf.ps1 state rm runpod_network_volume.models
pwsh -File scripts/tf.ps1 import runpod_network_volume.models <volume-id>
pwsh -File scripts/tf.ps1 -EnvFile .env.staging plan
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'env-common.ps1')

$repoRoot = Split-Path -Parent $PSScriptRoot
$infraDir = Join-Path $repoRoot 'infra'

# This script intentionally has no param() block so that terraform flags like
# -auto-approve pass through unbound. Parse only our own option manually.
$rawArgs = @($args)
$envFile = Join-Path $repoRoot '.env'
$terraformArgs = @()
for ($i = 0; $i -lt $rawArgs.Count; $i++) {
    if ($rawArgs[$i] -eq '-EnvFile' -and ($i + 1) -lt $rawArgs.Count) {
        $envFile = $rawArgs[$i + 1]
        $i++
        continue
    }
    $terraformArgs += $rawArgs[$i]
}

if ($terraformArgs.Count -eq 0) {
    Write-Host 'Usage: pwsh -File scripts/tf.ps1 [-EnvFile <path>] <terraform args...>'
    Write-Host 'Examples:'
    Write-Host '  pwsh -File scripts/tf.ps1 init'
    Write-Host '  pwsh -File scripts/tf.ps1 plan'
    Write-Host '  pwsh -File scripts/tf.ps1 apply -auto-approve'
    Write-Host '  pwsh -File scripts/tf.ps1 output -raw volume_id'
    Write-Host '  pwsh -File scripts/tf.ps1 state rm runpod_network_volume.models'
    exit 2
}

$loaded = Import-DotEnv -Path $envFile
if ($loaded -gt 0) {
    Write-Host "Loaded $loaded variable(s) from $envFile"
}

if (-not (Get-Command terraform -ErrorAction SilentlyContinue)) {
    throw 'terraform not found on PATH. Install Terraform >= 1.5 and retry.'
}

& terraform "-chdir=$infraDir" @terraformArgs
exit $LASTEXITCODE
