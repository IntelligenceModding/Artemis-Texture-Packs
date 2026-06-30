[CmdletBinding()]
param(
    [string]$ManifestUrl = 'https://piston-meta.mojang.com/mc/game/version_manifest_v2.json',
    [string]$BaselineExclusive = '1.12.2',
    [string]$OutputPath = 'config/minecraft-release-version-matrix.psd1'
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

function Format-BooleanLiteral {
    param([Parameter(Mandatory = $true)][bool]$Value)

    if ($Value) {
        return '$true'
    }

    return '$false'
}

function Format-PackFormatLiteral {
    param([Parameter(Mandatory = $true)]$PackFormat)

    if ($PackFormat -is [int] -or $PackFormat -is [long]) {
        return [string]$PackFormat
    }

    return "@{ major = $($PackFormat.major); minor = $($PackFormat.minor) }"
}

function Get-JavapFieldConstant {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string[]]$JavapLines,
        [Parameter(Mandatory = $true)][string]$FieldName
    )

    for ($index = 0; $index -lt $JavapLines.Count; $index++) {
        if ($JavapLines[$index] -match "^\s+public static final int $([Regex]::Escape($FieldName));") {
            for ($inner = $index + 1; $inner -lt [Math]::Min($index + 8, $JavapLines.Count); $inner++) {
                if ($JavapLines[$inner] -match 'ConstantValue: int (?<value>-?\d+)') {
                    return [int]$Matches.value
                }
            }
        }
    }

    throw "Unable to find ConstantValue for field '$FieldName'."
}

function Get-DirectSharedConstantsPackFormat {
    param([Parameter(Mandatory = $true)][string]$JarPath)

    $javapLines = @(javap -classpath $JarPath -verbose net.minecraft.SharedConstants)
    if ($LASTEXITCODE -ne 0) {
        throw "javap failed for net.minecraft.SharedConstants."
    }

    $hasMajor = $false
    foreach ($line in $javapLines) {
        if ($line -match 'public static final int RESOURCE_PACK_FORMAT_MAJOR;') {
            $hasMajor = $true
            break
        }
    }

    if ($hasMajor) {
        return [ordered]@{
            major = Get-JavapFieldConstant -JavapLines $javapLines -FieldName 'RESOURCE_PACK_FORMAT_MAJOR'
            minor = Get-JavapFieldConstant -JavapLines $javapLines -FieldName 'RESOURCE_PACK_FORMAT_MINOR'
        }
    }

    return Get-JavapFieldConstant -JavapLines $javapLines -FieldName 'RESOURCE_PACK_FORMAT'
}

function Get-MappedSharedConstantsPackFormat {
    param(
        [Parameter(Mandatory = $true)][string]$JarPath,
        [Parameter(Mandatory = $true)][string[]]$MappingLines
    )

    $classLine = $MappingLines | Where-Object { $_ -match '^net\.minecraft\.SharedConstants -> ' } | Select-Object -First 1
    if (-not $classLine) {
        throw "Mappings do not contain net.minecraft.SharedConstants."
    }

    $obfuscatedClass = (($classLine -split ' -> ')[1]).TrimEnd(':')
    $majorLine = $MappingLines | Where-Object { $_ -match '^\s+int RESOURCE_PACK_FORMAT_MAJOR -> ' } | Select-Object -First 1
    $minorLine = $MappingLines | Where-Object { $_ -match '^\s+int RESOURCE_PACK_FORMAT_MINOR -> ' } | Select-Object -First 1
    $singleLine = $MappingLines | Where-Object { $_ -match '^\s+int RESOURCE_PACK_FORMAT -> ' } | Select-Object -First 1

    $javapLines = @(javap -classpath $JarPath -verbose $obfuscatedClass)
    if ($LASTEXITCODE -ne 0) {
        throw "javap failed for mapped SharedConstants class '$obfuscatedClass'."
    }

    if ($majorLine -and $minorLine) {
        $majorField = (($majorLine -split ' -> ')[1]).Trim()
        $minorField = (($minorLine -split ' -> ')[1]).Trim()

        return [ordered]@{
            major = Get-JavapFieldConstant -JavapLines $javapLines -FieldName $majorField
            minor = Get-JavapFieldConstant -JavapLines $javapLines -FieldName $minorField
        }
    }

    if ($singleLine) {
        $singleField = (($singleLine -split ' -> ')[1]).Trim()
        return Get-JavapFieldConstant -JavapLines $javapLines -FieldName $singleField
    }

    throw "Mappings do not expose RESOURCE_PACK_FORMAT fields."
}

function Get-PackFormatFromPackMcmeta {
    param([Parameter(Mandatory = $true)]$Zip)

    $entry = @($Zip.Entries | Where-Object { $_.FullName -eq 'pack.mcmeta' })[0]
    if (-not $entry) {
        throw "Client jar does not contain a root pack.mcmeta fallback."
    }

    $reader = New-Object System.IO.StreamReader($entry.Open())
    try {
        $content = $reader.ReadToEnd() | ConvertFrom-Json
    }
    finally {
        $reader.Dispose()
    }

    return [int]$content.pack.pack_format
}

function Get-PackFormatForVersion {
    param(
        [Parameter(Mandatory = $true)]$VersionEntry,
        [Parameter(Mandatory = $true)]$VersionMetadata
    )

    $jarPath = Join-Path -Path $env:TEMP -ChildPath ("artemis-pack-format-" + $VersionEntry.id + ".jar")
    $mappingPath = Join-Path -Path $env:TEMP -ChildPath ("artemis-pack-format-" + $VersionEntry.id + ".txt")
    $zip = $null

    try {
        Invoke-WebRequest -UseBasicParsing -Uri $VersionMetadata.downloads.client.url -OutFile $jarPath
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $zip = [System.IO.Compression.ZipFile]::OpenRead($jarPath)

        $hasRootPackMcmeta = @($zip.Entries | Where-Object { $_.FullName -eq 'pack.mcmeta' }).Count -gt 0
        if ($hasRootPackMcmeta) {
            return Get-PackFormatFromPackMcmeta -Zip $zip
        }

        $hasDirectSharedConstants = @($zip.Entries | Where-Object { $_.FullName -eq 'net/minecraft/SharedConstants.class' }).Count -gt 0
        if ($hasDirectSharedConstants) {
            return Get-DirectSharedConstantsPackFormat -JarPath $jarPath
        }

        $mappingUrl = $null
        $downloadsProperties = @($VersionMetadata.downloads.PSObject.Properties | ForEach-Object { $_.Name })
        if ('server_mappings' -in $downloadsProperties -and $VersionMetadata.downloads.server_mappings) {
            $mappingUrl = $VersionMetadata.downloads.server_mappings.url
        }
        elseif ('client_mappings' -in $downloadsProperties -and $VersionMetadata.downloads.client_mappings) {
            $mappingUrl = $VersionMetadata.downloads.client_mappings.url
        }

        if ($mappingUrl) {
            Invoke-WebRequest -UseBasicParsing -Uri $mappingUrl -OutFile $mappingPath
            $mappingLines = @(Get-Content -LiteralPath $mappingPath)
            return Get-MappedSharedConstantsPackFormat -JarPath $jarPath -MappingLines $mappingLines
        }
        throw "Unable to determine pack format for version '$($VersionEntry.id)' from official jar metadata or mappings."
    }
    finally {
        if ($zip) {
            $zip.Dispose()
        }

        if (Test-Path -LiteralPath $jarPath) {
            Remove-Item -LiteralPath $jarPath -Force
        }

        if (Test-Path -LiteralPath $mappingPath) {
            Remove-Item -LiteralPath $mappingPath -Force
        }
    }
}

$repoRoot = Split-Path -Path $PSScriptRoot -Parent
$outputFullPath = Resolve-FullPath -BasePath $repoRoot -Path $OutputPath
Ensure-Directory -Path ([System.IO.Path]::GetDirectoryName($outputFullPath))

$manifest = (Invoke-WebRequest -UseBasicParsing -Uri $ManifestUrl | Select-Object -ExpandProperty Content) | ConvertFrom-Json
$releaseVersionsDescending = @($manifest.versions | Where-Object { $_.type -eq 'release' })
[array]::Reverse($releaseVersionsDescending)

$started = $false
$releaseVersions = New-Object System.Collections.Generic.List[object]
foreach ($release in $releaseVersionsDescending) {
    if (-not $started) {
        if ($release.id -eq $BaselineExclusive) {
            $started = $true
        }
        continue
    }

    $releaseVersions.Add($release)
}

if ($releaseVersions.Count -eq 0) {
    throw "No release versions were found after baseline '$BaselineExclusive'."
}

$versionIds = @($releaseVersions | ForEach-Object { $_.id })
$supportedFormatsStartIndex = $versionIds.IndexOf('1.20.2')
if ($supportedFormatsStartIndex -lt 0) {
    throw "Unable to locate the supported_formats breakpoint version '1.20.2' in the official release list."
}

$versionEntries = New-Object System.Collections.Generic.List[hashtable]

for ($index = 0; $index -lt $releaseVersions.Count; $index++) {
    $release = $releaseVersions[$index]
    Write-Output "Syncing $($release.id)..."
    $metadata = (Invoke-WebRequest -UseBasicParsing -Uri $release.url | Select-Object -ExpandProperty Content) | ConvertFrom-Json
    $packFormat = Get-PackFormatForVersion -VersionEntry $release -VersionMetadata $metadata
    $emitSupportedFormats = $index -ge $supportedFormatsStartIndex

    $versionEntries.Add(@{
        Id = [string]$release.id
        Enabled = $true
        PackFormat = $packFormat
        EmitSupportedFormats = $emitSupportedFormats
    })
}

$lines = New-Object System.Collections.Generic.List[string]
$lines.Add('@{')
$lines.Add("    GeneratedAtUtc = '$([DateTime]::UtcNow.ToString('o'))'")
$lines.Add("    Source = 'Official Mojang version manifest plus official release jars/mappings'")
$lines.Add("    BaselineExclusive = '$BaselineExclusive'")
$lines.Add('    Versions = @(')

for ($index = 0; $index -lt $versionEntries.Count; $index++) {
    $entry = $versionEntries[$index]
    $lines.Add('        @{')
    $lines.Add("            Id = '$($entry.Id)'")
    $lines.Add("            Enabled = $(Format-BooleanLiteral -Value ([bool]$entry.Enabled))")
    $lines.Add("            PackFormat = $(Format-PackFormatLiteral -PackFormat $entry.PackFormat)")
    $lines.Add("            EmitSupportedFormats = $(Format-BooleanLiteral -Value ([bool]$entry.EmitSupportedFormats))")
    $lines.Add('        }' + $(if ($index -lt $versionEntries.Count - 1) { '' } else { '' }))
}

$lines.Add('    )')
$lines.Add('}')

Set-Content -LiteralPath $outputFullPath -Value $lines -Encoding UTF8
Write-Output "Wrote version matrix to $outputFullPath"
