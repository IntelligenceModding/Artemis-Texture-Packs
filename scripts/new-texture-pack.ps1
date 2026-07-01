[CmdletBinding()]
param(
    [string]$Name,
    [string]$MinVersion = '1.13',
    [string]$ConfigPath = 'config/texture-pack.build.psd1'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Resolve-FullPath {
    param(
        [Parameter(Mandatory = $true)][string]$BasePath,
        [Parameter(Mandatory = $true)][string]$Path
    )

    if ([System.IO.Path]::IsPathRooted($Path)) {
        return [System.IO.Path]::GetFullPath($Path)
    }

    return [System.IO.Path]::GetFullPath((Join-Path -Path $BasePath -ChildPath $Path))
}

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

function Get-ScaffoldDirectories {
    param(
        [Parameter(Mandatory = $true)][string]$RepoRoot,
        [Parameter(Mandatory = $true)][string]$ConfigPath
    )

    $configFullPath = Resolve-FullPath -BasePath $RepoRoot -Path $ConfigPath
    if (-not (Test-Path -LiteralPath $configFullPath)) {
        throw "Config file not found: $configFullPath"
    }

    $config = Import-PowerShellDataFile -Path $configFullPath
    $canonicalAssetsFolder = [string]$config.CanonicalAssetsFolder
    $autoSortFolder = [string]$config.AutoSortFolder
    $directories = New-Object System.Collections.Generic.List[string]
    $seen = @{}

    function Add-UniqueDirectory {
        param([Parameter(Mandatory = $true)][string]$RelativePath)

        $normalizedPath = $RelativePath -replace '\\', '/'
        if (-not $seen.ContainsKey($normalizedPath)) {
            $seen[$normalizedPath] = $true
            $directories.Add($normalizedPath)
        }
    }

    Add-UniqueDirectory -RelativePath $canonicalAssetsFolder
    Add-UniqueDirectory -RelativePath (Join-Path -Path $canonicalAssetsFolder -ChildPath 'minecraft')
    Add-UniqueDirectory -RelativePath $autoSortFolder

    foreach ($mapping in @($config.AutoSortMappings)) {
        Add-UniqueDirectory -RelativePath (Join-Path -Path $autoSortFolder -ChildPath ([string]$mapping.Folder))
    }

    $recommendedSubfolders = @{
        textures = @('block', 'item', 'particle')
        models   = @('block', 'item')
    }

    foreach ($folderName in $recommendedSubfolders.Keys) {
        if (-not (@($config.AutoSortMappings | Where-Object { [string]$_.Folder -eq $folderName }).Count -gt 0)) {
            continue
        }

        foreach ($subfolderName in $recommendedSubfolders[$folderName]) {
            Add-UniqueDirectory -RelativePath (Join-Path -Path (Join-Path -Path $autoSortFolder -ChildPath $folderName) -ChildPath $subfolderName)
        }
    }

    return @($directories)
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

$directories = @(Get-ScaffoldDirectories -RepoRoot $repoRoot -ConfigPath $ConfigPath)

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
Write-Output "Add textures under: resource_packs/$packName/drop/textures/block or .../item or .../particle"
Write-Output "Add models under: resource_packs/$packName/drop/models/block or .../item"
