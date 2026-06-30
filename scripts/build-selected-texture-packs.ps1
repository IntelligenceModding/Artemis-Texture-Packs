[CmdletBinding()]
param(
    [string[]]$Pack,
    [switch]$Clean
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-RequestedPackNames {
    param([string]$RepoRoot)

    $packsRoot = Join-Path -Path $RepoRoot -ChildPath 'resource_packs'
    $availablePacks = @(Get-ChildItem -LiteralPath $packsRoot -Directory | Sort-Object Name | Select-Object -ExpandProperty Name)

    if ($availablePacks.Count -eq 0) {
        throw "No texture packs found in '$packsRoot'."
    }

    Write-Host 'Available texture packs:'
    foreach ($packName in $availablePacks) {
        Write-Host "  - $packName"
    }
    Write-Host ''

    $inputValue = Read-Host 'Enter texture pack name(s) to build (comma-separated)'
    if ([string]::IsNullOrWhiteSpace($inputValue)) {
        throw 'No texture pack names entered.'
    }

    $requestedPacks = @(
        $inputValue.Split(',', [System.StringSplitOptions]::RemoveEmptyEntries) |
            ForEach-Object { $_.Trim() } |
            Where-Object { $_ } |
            Select-Object -Unique
    )

    if ($requestedPacks.Count -eq 0) {
        throw 'No valid texture pack names were entered.'
    }

    return $requestedPacks
}

$repoRoot = Split-Path -Path $PSScriptRoot -Parent

if (-not $Pack -or $Pack.Count -eq 0) {
    $Pack = @(Get-RequestedPackNames -RepoRoot $repoRoot)
}

$buildScriptPath = Join-Path -Path $PSScriptRoot -ChildPath 'build-texture-packs.ps1'
$invokeParameters = @{
    Pack = $Pack
}

if ($Clean) {
    $invokeParameters.Clean = $true
}

& $buildScriptPath @invokeParameters
