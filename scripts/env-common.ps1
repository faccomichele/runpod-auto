# Shared helpers for the repo scripts. Dot-source this file:
#   . (Join-Path $PSScriptRoot 'env-common.ps1')

function Import-DotEnv {
    <#
    .SYNOPSIS
    Loads KEY=VALUE pairs from a .env file into the current process.

    .DESCRIPTION
    Supports blank lines, # comments, an optional `export ` prefix, quoted
    values, and unquoted inline comments (value # comment).
    Existing process environment variables are never overridden.

    Returns the number of variables that were set.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        return 0
    }

    $loaded = 0
    foreach ($line in [System.IO.File]::ReadAllLines($Path)) {
        $trimmed = $line.Trim()
        if (-not $trimmed -or $trimmed.StartsWith('#')) {
            continue
        }
        if ($trimmed -notmatch '^(?:export\s+)?([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*)$') {
            continue
        }

        $name = $matches[1]
        $value = $matches[2].Trim()

        if ($value.StartsWith('"') -or $value.StartsWith("'")) {
            $quote = $value.Substring(0, 1)
            $end = $value.IndexOf($quote, 1)
            if ($end -gt 0) {
                $value = $value.Substring(1, $end - 1)
            }
        }
        else {
            $comment = $value.IndexOf(' #')
            if ($comment -ge 0) {
                $value = $value.Substring(0, $comment).Trim()
            }
        }

        if (-not (Test-Path "Env:$name")) {
            Set-Item -Path "Env:$name" -Value $value
            $loaded++
        }
    }

    return $loaded
}
