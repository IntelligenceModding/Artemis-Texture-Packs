[CmdletBinding()]
param(
    [string]$Name,
    [string]$MinVersion = '1.13'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Ensure-Directory {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
    }
}

function Convert-ToPackFolderName {
    param([Parameter(Mandatory = $true)][string]$RawName)

    $normalized = $RawName.Trim().ToLowerInvariant()
    $normalized = $normalized -replace '\s+', '_'
    $normalized = $normalized -replace '[^a-z0-9_-]', ''
    $normalized = $normalized.Trim('_-')

    if ([string]::IsNullOrWhiteSpace($normalized)) {
        throw 'Pack name must contain at least one letter or number.'
    }

    return $normalized
}

if (-not $Name) {
    $Name = Read-Host 'Enter the new resource pack name'
}

$packName = Convert-ToPackFolderName -RawName $Name
$repoRoot = Split-Path -Path $PSScriptRoot -Parent
$packRoot = Join-Path -Path $repoRoot -ChildPath 'resource_packs'
$targetRoot = Join-Path -Path $packRoot -ChildPath $packName

if (Test-Path -LiteralPath $targetRoot) {
    throw "Pack folder already exists: $targetRoot"
}

$directories = @(
    'assets'
    'assets/minecraft'
    'drop'
    'drop/textures'
    'drop/textures/block'
    'drop/textures/item'
    'drop/models'
    'drop/models/block'
    'drop/models/item'
    'drop/blockstates'
    'drop/lang'
    'drop/font'
    'drop/particles'
    'drop/atlases'
    'drop/shaders'
    'drop/sounds'
    'drop/texts'
)

foreach ($relativeDirectory in $directories) {
    Ensure-Directory -Path (Join-Path -Path $targetRoot -ChildPath $relativeDirectory)
}

$packBuildConfig = @"
@{
    MinVersion = '$MinVersion'
}
"@

Set-Content -LiteralPath (Join-Path -Path $targetRoot -ChildPath 'pack.build.psd1') -Value $packBuildConfig -Encoding UTF8

Write-Output "Created resource pack scaffold: $targetRoot"
Write-Output "Add your icon as: resource_packs/$packName/pack.png"
Write-Output "Add textures under: resource_packs/$packName/drop/textures/block or .../item"
Write-Output "Add models under: resource_packs/$packName/drop/models/block or .../item"
