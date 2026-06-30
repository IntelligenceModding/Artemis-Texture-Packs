[CmdletBinding()]
param(
    [string]$ConfigPath = 'config/texture-pack.build.psd1',
    [string[]]$Version,
    [string[]]$Pack,
    [switch]$ListVersions,
    [switch]$ListPacks,
    [switch]$Clean
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

function Get-NormalizedRelativePath {
    param(
        [Parameter(Mandatory = $true)][string]$BasePath,
        [Parameter(Mandatory = $true)][string]$FullPath
    )

    $baseResolved = (Resolve-Path -LiteralPath $BasePath).Path
    $fullResolved = (Resolve-Path -LiteralPath $FullPath).Path

    $baseUri = New-Object System.Uri(($baseResolved.TrimEnd('\') + '\'))
    $fullUri = New-Object System.Uri($fullResolved)
    $relative = [System.Uri]::UnescapeDataString($baseUri.MakeRelativeUri($fullUri).ToString())

    return ($relative -replace '\\', '/').TrimStart('./')
}

function Convert-Tokens {
    param(
        [Parameter(Mandatory = $true)][string]$Value,
        [Parameter(Mandatory = $true)][hashtable]$Tokens
    )

    $result = $Value
    foreach ($entry in $Tokens.GetEnumerator()) {
        $result = $result.Replace("{$($entry.Key)}", [string]$entry.Value)
    }

    return $result
}

function ConvertTo-Hashtable {
    param([Parameter(Mandatory = $true)]$InputObject)

    if ($null -eq $InputObject) {
        return @{}
    }

    if ($InputObject -is [hashtable]) {
        $copy = @{}
        foreach ($key in $InputObject.Keys) {
            $copy[$key] = ConvertTo-Hashtable -InputObject $InputObject[$key]
        }
        return $copy
    }

    if ($InputObject -is [System.Collections.IDictionary]) {
        $copy = @{}
        foreach ($key in $InputObject.Keys) {
            $copy[$key] = ConvertTo-Hashtable -InputObject $InputObject[$key]
        }
        return $copy
    }

    if (($InputObject -is [System.Collections.IEnumerable]) -and -not ($InputObject -is [string])) {
        $list = @()
        foreach ($item in $InputObject) {
            $list += ,(ConvertTo-Hashtable -InputObject $item)
        }
        return $list
    }

    if ($InputObject.PSObject -and @($InputObject.PSObject.Properties).Count -gt 0 -and $InputObject -isnot [string]) {
        $copy = @{}
        foreach ($property in $InputObject.PSObject.Properties) {
            $copy[$property.Name] = ConvertTo-Hashtable -InputObject $property.Value
        }
        return $copy
    }

    return $InputObject
}

function Get-HashtableValueOrDefault {
    param(
        [Parameter(Mandatory = $true)][hashtable]$Table,
        [Parameter(Mandatory = $true)][string]$Key,
        $DefaultValue
    )

    if ($Table.ContainsKey($Key)) {
        return $Table[$Key]
    }

    return $DefaultValue
}

function Merge-Hashtable {
    param(
        [Parameter(Mandatory = $true)][hashtable]$Base,
        [Parameter(Mandatory = $true)][hashtable]$Overlay
    )

    foreach ($key in $Overlay.Keys) {
        if ($Base.ContainsKey($key) -and $Base[$key] -is [hashtable] -and $Overlay[$key] -is [hashtable]) {
            Merge-Hashtable -Base $Base[$key] -Overlay $Overlay[$key]
            continue
        }

        $Base[$key] = $Overlay[$key]
    }

    return $Base
}

function Normalize-VersionConfig {
    param([Parameter(Mandatory = $true)]$VersionConfig)

    $normalized = ConvertTo-Hashtable -InputObject $VersionConfig
    foreach ($key in @('Renames', 'PathRewrites', 'Remove', 'Required')) {
        if (-not $normalized.ContainsKey($key) -or $null -eq $normalized[$key]) {
            $normalized[$key] = @()
        }
    }

    foreach ($key in @('PackMetadata', 'RootMetadata')) {
        if (-not $normalized.ContainsKey($key) -or $null -eq $normalized[$key]) {
            $normalized[$key] = @{}
        }
    }

    if (-not $normalized.ContainsKey('Enabled') -or $null -eq $normalized['Enabled']) {
        $normalized['Enabled'] = $true
    }

    return $normalized
}

function Convert-PackFormatValue {
    param([Parameter(Mandatory = $true)]$Value)

    if ($Value -is [int] -or $Value -is [long]) {
        return [int]$Value
    }

    if (
        $Value -is [hashtable] -or
        $Value -is [System.Collections.IDictionary] -or
        (
            $Value -isnot [string] -and
            $Value -isnot [bool] -and
            @($Value.PSObject.Properties.Name).Count -gt 0
        )
    ) {
        $normalized = ConvertTo-Hashtable -InputObject $Value
        if (-not $normalized.ContainsKey('major')) {
            throw "PackFormat object is missing 'major'."
        }

        if (-not $normalized.ContainsKey('minor')) {
            $normalized['minor'] = 0
        }

        return [ordered]@{
            major = [int]$normalized.major
            minor = [int]$normalized.minor
        }
    }

    throw "Unsupported PackFormat value type: $($Value.GetType().FullName)"
}

function Format-PackFormatValue {
    param([Parameter(Mandatory = $true)]$Value)

    $normalized = Convert-PackFormatValue -Value $Value
    if ($normalized -is [int]) {
        return [string]$normalized
    }

    return "$($normalized.major).$($normalized.minor)"
}

function Convert-PackFormatMetadataValue {
    param([Parameter(Mandatory = $true)]$Value)

    $normalized = Convert-PackFormatValue -Value $Value
    if ($normalized -is [int]) {
        return $normalized
    }

    if ([int]$normalized.minor -eq 0) {
        return [int]$normalized.major
    }

    return @(
        [int]$normalized.major
        [int]$normalized.minor
    )
}

function New-ExactSupportedFormatsRange {
    param([Parameter(Mandatory = $true)]$PackFormat)

    $normalized = Convert-PackFormatValue -Value $PackFormat
    return [ordered]@{
        min_inclusive = $normalized
        max_inclusive = $normalized
    }
}

function Get-EffectiveSupportedFormats {
    param([Parameter(Mandatory = $true)]$VersionConfig)

    if ($VersionConfig.ContainsKey('SupportedFormats') -and $VersionConfig.SupportedFormats) {
        return ConvertTo-Hashtable -InputObject $VersionConfig.SupportedFormats
    }

    if ($VersionConfig.ContainsKey('EmitSupportedFormats') -and $VersionConfig.EmitSupportedFormats) {
        return New-ExactSupportedFormatsRange -PackFormat $VersionConfig.PackFormat
    }

    return $null
}

function Test-RuleMatch {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Rule
    )

    if ($Rule.EndsWith('/')) {
        return $Path.StartsWith($Rule, [System.StringComparison]::OrdinalIgnoreCase)
    }

    return $Path.Equals($Rule, [System.StringComparison]::OrdinalIgnoreCase)
}

function Test-IgnoredSourceFile {
    param([Parameter(Mandatory = $true)][string]$Name)

    return $Name -in @('.gitkeep', '.gitignore', 'Thumbs.db', '.DS_Store')
}

function Convert-ToPackDisplayName {
    param([Parameter(Mandatory = $true)][string]$PackFolderName)

    $spaced = ($PackFolderName -replace '[_-]+', ' ').Trim()
    if ([string]::IsNullOrWhiteSpace($spaced)) {
        return $PackFolderName
    }

    return [System.Globalization.CultureInfo]::InvariantCulture.TextInfo.ToTitleCase($spaced.ToLowerInvariant())
}

function Get-PackDirectories {
    param(
        [Parameter(Mandatory = $true)][string]$RepoRoot,
        [Parameter(Mandatory = $true)]$Config,
        [string[]]$RequestedPackNames
    )

    $packsRoot = Resolve-FullPath -BasePath $RepoRoot -Path ([string]$Config.PackRoot)
    if (-not (Test-Path -LiteralPath $packsRoot)) {
        throw "Pack root not found: $packsRoot"
    }

    $packDirectories = @(Get-ChildItem -LiteralPath $packsRoot -Directory | Sort-Object Name)

    if ($RequestedPackNames) {
        $lookup = @{}
        foreach ($requested in $RequestedPackNames) {
            $lookup[$requested] = $true
        }

        $packDirectories = @($packDirectories | Where-Object { $lookup.ContainsKey($_.Name) })
        if ($packDirectories.Count -ne $lookup.Keys.Count) {
            $found = @($packDirectories | ForEach-Object { $_.Name })
            $missing = @($lookup.Keys | Where-Object { $_ -notin $found })
            throw "Unknown pack name(s): $($missing -join ', ')"
        }
    }

    return $packDirectories
}

function Get-PackBuildOptions {
    param(
        [Parameter(Mandatory = $true)]$PackDirectory,
        [Parameter(Mandatory = $true)]$Config
    )

    $configFileName = [string]$Config.PackBuildConfigFile
    $configPath = Join-Path -Path $PackDirectory.FullName -ChildPath $configFileName
    if (-not (Test-Path -LiteralPath $configPath)) {
        return @{}
    }

    return Import-PowerShellDataFile -Path $configPath
}

function Get-PackSelectedVersions {
    param(
        [Parameter(Mandatory = $true)]$PackDirectory,
        [Parameter(Mandatory = $true)]$Config,
        [Parameter(Mandatory = $true)][object[]]$GloballySelectedVersions
    )

    $packOptions = Get-PackBuildOptions -PackDirectory $PackDirectory -Config $Config
    if ($packOptions.Count -eq 0) {
        return @($GloballySelectedVersions)
    }

    $selectedVersions = @($GloballySelectedVersions)
    $versionOrder = @{}
    $orderedVersions = @($Config.Versions)
    for ($index = 0; $index -lt $orderedVersions.Count; $index++) {
        $versionOrder[[string]$orderedVersions[$index].Id] = $index
    }

    function Assert-KnownPackVersionOption {
        param(
            [Parameter(Mandatory = $true)][string]$VersionId,
            [Parameter(Mandatory = $true)][string]$OptionName
        )

        if (-not $versionOrder.ContainsKey($VersionId)) {
            throw "Pack '$($PackDirectory.Name)' requests unknown version id '$VersionId' in option '$OptionName' inside $([string]$Config.PackBuildConfigFile)."
        }
    }

    if ($packOptions.ContainsKey('Versions') -and $packOptions.Versions) {
        $lookup = @{}
        foreach ($versionId in @($packOptions.Versions)) {
            $lookup[[string]$versionId] = $true
        }

        $selectedVersions = @($selectedVersions | Where-Object { $lookup.ContainsKey($_.Id) })

        $foundIds = @($selectedVersions | ForEach-Object { $_.Id })
        $missing = @($lookup.Keys | Where-Object { $_ -notin $foundIds })
        if ($missing.Count -gt 0) {
            throw "Pack '$($PackDirectory.Name)' requests unknown version id(s) in $([string]$Config.PackBuildConfigFile): $($missing -join ', ')"
        }
    }

    if ($packOptions.ContainsKey('ExcludeVersions') -and $packOptions.ExcludeVersions) {
        $lookup = @{}
        foreach ($versionId in @($packOptions.ExcludeVersions)) {
            $lookup[[string]$versionId] = $true
        }

        $selectedVersions = @($selectedVersions | Where-Object { -not $lookup.ContainsKey($_.Id) })
    }

    if ($packOptions.ContainsKey('MinVersion') -and $packOptions.MinVersion) {
        $minVersionId = [string]$packOptions.MinVersion
        Assert-KnownPackVersionOption -VersionId $minVersionId -OptionName 'MinVersion'
        $minIndex = [int]$versionOrder[$minVersionId]
        $selectedVersions = @($selectedVersions | Where-Object { [int]$versionOrder[$_.Id] -ge $minIndex })
    }

    if ($packOptions.ContainsKey('MaxVersion') -and $packOptions.MaxVersion) {
        $maxVersionId = [string]$packOptions.MaxVersion
        Assert-KnownPackVersionOption -VersionId $maxVersionId -OptionName 'MaxVersion'
        $maxIndex = [int]$versionOrder[$maxVersionId]
        $selectedVersions = @($selectedVersions | Where-Object { [int]$versionOrder[$_.Id] -le $maxIndex })
    }

    if ($packOptions.ContainsKey('AfterVersion') -and $packOptions.AfterVersion) {
        $afterVersionId = [string]$packOptions.AfterVersion
        Assert-KnownPackVersionOption -VersionId $afterVersionId -OptionName 'AfterVersion'
        $afterIndex = [int]$versionOrder[$afterVersionId]
        $selectedVersions = @($selectedVersions | Where-Object { [int]$versionOrder[$_.Id] -gt $afterIndex })
    }

    if ($packOptions.ContainsKey('BeforeVersion') -and $packOptions.BeforeVersion) {
        $beforeVersionId = [string]$packOptions.BeforeVersion
        Assert-KnownPackVersionOption -VersionId $beforeVersionId -OptionName 'BeforeVersion'
        $beforeIndex = [int]$versionOrder[$beforeVersionId]
        $selectedVersions = @($selectedVersions | Where-Object { [int]$versionOrder[$_.Id] -lt $beforeIndex })
    }

    return $selectedVersions
}

function Get-PackTokens {
    param(
        [Parameter(Mandatory = $true)]$Config,
        [Parameter(Mandatory = $true)]$PackDirectory,
        [Parameter(Mandatory = $true)]$VersionConfig
    )

    $packName = $PackDirectory.Name
    return @{
        PackName = $packName
        PackDisplayName = Convert-ToPackDisplayName -PackFolderName $packName
        VersionId = [string]$VersionConfig.Id
        BaseDescription = [string]$Config.BaseDescription
    }
}

function Get-TransformedPath {
    param(
        [Parameter(Mandatory = $true)][string]$RelativePath,
        [Parameter(Mandatory = $true)]$VersionConfig
    )

    $path = $RelativePath

    foreach ($rename in @(Get-HashtableValueOrDefault -Table $VersionConfig -Key 'Renames' -DefaultValue @())) {
        if ($null -eq $rename) {
            continue
        }

        if ($path.Equals([string]$rename.From, [System.StringComparison]::OrdinalIgnoreCase)) {
            $path = [string]$rename.To
        }
    }

    foreach ($rewrite in @(Get-HashtableValueOrDefault -Table $VersionConfig -Key 'PathRewrites' -DefaultValue @())) {
        if ($null -eq $rewrite) {
            continue
        }

        $from = [string]$rewrite.From
        $to = [string]$rewrite.To
        if ($path.StartsWith($from, [System.StringComparison]::OrdinalIgnoreCase)) {
            $path = $to + $path.Substring($from.Length)
        }
    }

    foreach ($rule in @(Get-HashtableValueOrDefault -Table $VersionConfig -Key 'Remove' -DefaultValue @())) {
        if (Test-RuleMatch -Path $path -Rule ([string]$rule)) {
            return $null
        }
    }

    return $path
}

function New-PackMcmetaObject {
    param(
        [Parameter(Mandatory = $true)][hashtable]$Tokens,
        [Parameter(Mandatory = $true)]$VersionConfig
    )

    $description = if ($VersionConfig.ContainsKey('Description') -and $VersionConfig.Description) {
        Convert-Tokens -Value ([string]$VersionConfig.Description) -Tokens $Tokens
    }
    else {
        Convert-Tokens -Value ([string]$Tokens.BaseDescription) -Tokens $Tokens
    }

    $normalizedPackFormat = Convert-PackFormatValue -Value $VersionConfig.PackFormat
    $packNode = [ordered]@{
        description = $description
    }

    if ($normalizedPackFormat -is [int]) {
        $packNode.pack_format = $normalizedPackFormat
    }
    else {
        $packNode.min_format = Convert-PackFormatMetadataValue -Value $normalizedPackFormat
        $packNode.max_format = Convert-PackFormatMetadataValue -Value $normalizedPackFormat
    }

    $supportedFormats = Get-EffectiveSupportedFormats -VersionConfig $VersionConfig
    if ($null -ne $supportedFormats -and $normalizedPackFormat -is [int]) {
        $packNode.supported_formats = $supportedFormats
    }

    if ($VersionConfig.ContainsKey('PackMetadata') -and $VersionConfig.PackMetadata) {
        $packNode = Merge-Hashtable -Base (ConvertTo-Hashtable -InputObject $packNode) -Overlay (ConvertTo-Hashtable -InputObject $VersionConfig.PackMetadata)
    }

    $rootNode = [ordered]@{
        pack = $packNode
    }

    if ($VersionConfig.ContainsKey('RootMetadata') -and $VersionConfig.RootMetadata) {
        $rootNode = Merge-Hashtable -Base (ConvertTo-Hashtable -InputObject $rootNode) -Overlay (ConvertTo-Hashtable -InputObject $VersionConfig.RootMetadata)
    }

    return $rootNode
}

function Get-PackRouteCachePath {
    param(
        [Parameter(Mandatory = $true)][string]$RepoRoot,
        [Parameter(Mandatory = $true)]$Config,
        [Parameter(Mandatory = $true)]$PackDirectory,
        [Parameter(Mandatory = $true)]$VersionConfig
    )

    $cacheRoot = Resolve-FullPath -BasePath $RepoRoot -Path ([string]$Config.VanillaCatalogCacheRoot)
    return Join-Path -Path (Join-Path -Path $cacheRoot -ChildPath 'resolved-pack-routes') -ChildPath (Join-Path -Path $PackDirectory.Name -ChildPath "$([string]$VersionConfig.Id).json")
}

function Get-PackRouteCache {
    param(
        [Parameter(Mandatory = $true)][string]$RepoRoot,
        [Parameter(Mandatory = $true)]$Config,
        [Parameter(Mandatory = $true)]$PackDirectory,
        [Parameter(Mandatory = $true)]$VersionConfig
    )

    $cachePath = Get-PackRouteCachePath -RepoRoot $RepoRoot -Config $Config -PackDirectory $PackDirectory -VersionConfig $VersionConfig
    if (-not (Test-Path -LiteralPath $cachePath)) {
        return @{}
    }

    return ConvertTo-Hashtable -InputObject ((Get-Content -LiteralPath $cachePath -Raw -Encoding UTF8) | ConvertFrom-Json)
}

function Save-PackRouteCache {
    param(
        [Parameter(Mandatory = $true)][string]$RepoRoot,
        [Parameter(Mandatory = $true)]$Config,
        [Parameter(Mandatory = $true)]$PackDirectory,
        [Parameter(Mandatory = $true)]$VersionConfig,
        [Parameter(Mandatory = $true)][hashtable]$RouteCache
    )

    $cachePath = Get-PackRouteCachePath -RepoRoot $RepoRoot -Config $Config -PackDirectory $PackDirectory -VersionConfig $VersionConfig
    Ensure-Directory -Path ([System.IO.Path]::GetDirectoryName($cachePath))
    Set-Content -LiteralPath $cachePath -Value ($RouteCache | ConvertTo-Json -Depth 100) -Encoding UTF8
}

function Get-MojangVersionManifest {
    param(
        [Parameter(Mandatory = $true)][string]$RepoRoot,
        [Parameter(Mandatory = $true)]$Config
    )

    $cacheRoot = Resolve-FullPath -BasePath $RepoRoot -Path ([string]$Config.VanillaCatalogCacheRoot)
    Ensure-Directory -Path $cacheRoot

    $manifestCachePath = Join-Path -Path $cacheRoot -ChildPath 'version_manifest_v2.json'
    $manifestUrl = [string]$Config.MojangVersionManifestUrl

    try {
        $content = Invoke-WebRequest -UseBasicParsing -Uri $manifestUrl | Select-Object -ExpandProperty Content
        Set-Content -LiteralPath $manifestCachePath -Value $content -Encoding UTF8
    }
    catch {
        if (-not (Test-Path -LiteralPath $manifestCachePath)) {
            throw "Unable to fetch Mojang version manifest from '$manifestUrl' and no local cache exists. $($_.Exception.Message)"
        }

        $content = Get-Content -LiteralPath $manifestCachePath -Raw -Encoding UTF8
    }

    return $content | ConvertFrom-Json
}

function Get-VanillaAssetCatalog {
    param(
        [Parameter(Mandatory = $true)][string]$RepoRoot,
        [Parameter(Mandatory = $true)]$Config,
        [Parameter(Mandatory = $true)]$VersionConfig
    )

    $cacheRoot = Resolve-FullPath -BasePath $RepoRoot -Path ([string]$Config.VanillaCatalogCacheRoot)
    Ensure-Directory -Path $cacheRoot

    $versionId = [string]$VersionConfig.Id
    $cachePath = Join-Path -Path $cacheRoot -ChildPath "$versionId.json"
    if (Test-Path -LiteralPath $cachePath) {
        return ConvertTo-Hashtable -InputObject ((Get-Content -LiteralPath $cachePath -Raw -Encoding UTF8) | ConvertFrom-Json)
    }

    $manifest = Get-MojangVersionManifest -RepoRoot $RepoRoot -Config $Config
    $versionEntry = @($manifest.versions | Where-Object { $_.id -eq $versionId })[0]
    if ($null -eq $versionEntry) {
        throw "Version '$versionId' is not present in Mojang's official version manifest."
    }

    try {
        $versionMetadata = (Invoke-WebRequest -UseBasicParsing -Uri $versionEntry.url | Select-Object -ExpandProperty Content) | ConvertFrom-Json
    }
    catch {
        throw "Unable to fetch Mojang metadata for version '$versionId'. $($_.Exception.Message)"
    }

    $clientJarUrl = $versionMetadata.downloads.client.url
    if (-not $clientJarUrl) {
        throw "Mojang metadata for version '$versionId' does not expose a client jar download."
    }

    $tempJarPath = Join-Path -Path $env:TEMP -ChildPath ("artemis-asset-catalog-" + $versionId + ".jar")

    $zip = $null
    try {
        Invoke-WebRequest -UseBasicParsing -Uri $clientJarUrl -OutFile $tempJarPath
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $zip = [System.IO.Compression.ZipFile]::OpenRead($tempJarPath)

        $byFileName = @{}
        foreach ($entry in $zip.Entries) {
            if ([string]::IsNullOrEmpty($entry.Name)) {
                continue
            }

            $normalizedPath = ($entry.FullName -replace '\\', '/')
            if (-not $normalizedPath.StartsWith('assets/', [System.StringComparison]::OrdinalIgnoreCase)) {
                continue
            }

            if (-not $byFileName.ContainsKey($entry.Name)) {
                $byFileName[$entry.Name] = @()
            }

            $byFileName[$entry.Name] += ,$normalizedPath
        }

        $catalog = [ordered]@{
            versionId = $versionId
            generatedAtUtc = [DateTime]::UtcNow.ToString('o')
            byFileName = $byFileName
        }

        $catalogJson = $catalog | ConvertTo-Json -Depth 100
        Set-Content -LiteralPath $cachePath -Value $catalogJson -Encoding UTF8
        return $catalog
    }
    catch {
        throw "Unable to build vanilla asset catalog for version '$versionId'. $($_.Exception.Message)"
    }
    finally {
        if ($zip) {
            $zip.Dispose()
        }

        if (Test-Path -LiteralPath $tempJarPath) {
            Remove-Item -LiteralPath $tempJarPath -Force
        }
    }
}

function Resolve-AutoAssetPath {
    param(
        [Parameter(Mandatory = $true)][string]$FileName,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$HintPath,
        [Parameter(Mandatory = $true)][string]$AssetPrefix,
        [Parameter(Mandatory = $true)]$Catalog,
        [string]$CategoryFolder = '',
        [hashtable]$RouteCache = @{},
        [string]$RouteCacheKey = ''
    )

    $normalizedPrefix = ($AssetPrefix -replace '\\', '/').TrimEnd('/') + '/'

    if ($RouteCacheKey -and $RouteCache.ContainsKey($RouteCacheKey)) {
        $cachedPath = [string]$RouteCache[$RouteCacheKey]
        if (
            $cachedPath.StartsWith($normalizedPrefix, [System.StringComparison]::OrdinalIgnoreCase) -and
            $Catalog.byFileName.ContainsKey($FileName) -and
            $cachedPath -in @($Catalog.byFileName[$FileName])
        ) {
            return $cachedPath
        }
    }

    if (-not $Catalog.byFileName.ContainsKey($FileName)) {
        throw "Unable to auto-sort '$FileName'. It does not exist in Mojang's vanilla asset catalog for version '$($Catalog.versionId)'. Put ambiguous or custom files under the pack's assets/ folder with their intended relative path."
    }

    $candidates = @($Catalog.byFileName[$FileName] | Where-Object {
        $_.StartsWith($normalizedPrefix, [System.StringComparison]::OrdinalIgnoreCase)
    })

    if ($candidates.Count -eq 0) {
        throw "Unable to auto-sort '$FileName'. It exists in vanilla Minecraft, but not under '$normalizedPrefix' for version '$($Catalog.versionId)'."
    }

    if ($HintPath) {
        $normalizedHint = ($HintPath -replace '\\', '/').Trim('/')
        $hinted = @($candidates | Where-Object { $_ -like "$normalizedPrefix$normalizedHint/$FileName" })
        if ($hinted.Count -gt 0) {
            $candidates = $hinted
        }
    }

    if ($candidates.Count -eq 1) {
        return $candidates[0]
    }

    if (
        -not $HintPath -and
        $CategoryFolder.Equals('models', [System.StringComparison]::OrdinalIgnoreCase)
    ) {
        $fileStem = [System.IO.Path]::GetFileNameWithoutExtension($FileName)
        $textureCandidates = if ($Catalog.byFileName.ContainsKey("$fileStem.png")) { @($Catalog.byFileName["$fileStem.png"]) } else { @() }
        $jsonCandidates = @($Catalog.byFileName[$FileName])
        $scoredCandidates = @()

        foreach ($candidate in $candidates) {
            $score = 0
            $relativeCandidate = $candidate.Substring($normalizedPrefix.Length)
            $firstSegment = ($relativeCandidate -split '/')[0]

            if (
                $firstSegment -eq 'block' -and
                "assets/minecraft/blockstates/$fileStem.json" -in $jsonCandidates
            ) {
                $score += 20
            }

            if ("assets/minecraft/textures/$firstSegment/$fileStem.png" -in $textureCandidates) {
                $score += 10
            }

            $scoredCandidates += [pscustomobject]@{
                Path = $candidate
                Score = $score
            }
        }

        $maxScore = ($scoredCandidates | Measure-Object -Property Score -Maximum).Maximum
        $bestCandidates = @($scoredCandidates | Where-Object { $_.Score -eq $maxScore } | ForEach-Object { $_.Path })
        if ($bestCandidates.Count -eq 1 -and $maxScore -gt 0) {
            return $bestCandidates[0]
        }
    }

    throw "Unable to auto-sort '$FileName'. Multiple vanilla target paths match: $($candidates -join ', '). Place that file under the pack's assets/ folder with the exact intended relative path."
}

function Get-PackInputFiles {
    param(
        [Parameter(Mandatory = $true)]$PackDirectory,
        [Parameter(Mandatory = $true)]$Config,
        [Parameter(Mandatory = $true)]$VersionConfig
    )

    $packRoot = $PackDirectory.FullName
    $packIconFile = [string]$Config.PackIconFile
    $canonicalAssetsFolder = [string]$Config.CanonicalAssetsFolder
    $autoSortFolder = [string]$Config.AutoSortFolder
    $autoSortMappings = @($Config.AutoSortMappings)

    $inputFiles = New-Object System.Collections.Generic.List[object]

    $definitions = @(
        @{ Kind = 'auto'; Path = $autoSortFolder; VirtualRoot = ''; Priority = 10 }
        @{ Kind = 'direct'; Path = $canonicalAssetsFolder; VirtualRoot = $canonicalAssetsFolder; Priority = 20 }
        @{ Kind = 'root'; Path = $packIconFile; VirtualRoot = $packIconFile; Priority = 30 }
    )

    foreach ($definition in $definitions) {
        $fullPath = Resolve-FullPath -BasePath $packRoot -Path ([string]$definition.Path)
        if (-not (Test-Path -LiteralPath $fullPath)) {
            continue
        }

        switch ($definition.Kind) {
            'root' {
                if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf)) {
                    continue
                }

                $inputFiles.Add([pscustomobject]@{
                    SourcePath = $fullPath
                    Kind = 'root'
                    VirtualPath = [string]$definition.VirtualRoot
                    HintPath = ''
                    SourceRelativePath = Get-NormalizedRelativePath -BasePath $packRoot -FullPath $fullPath
                    Priority = [int]$definition.Priority
                })
            }

            'direct' {
                $files = Get-ChildItem -LiteralPath $fullPath -File -Recurse
                foreach ($file in $files) {
                    if (Test-IgnoredSourceFile -Name $file.Name) {
                        continue
                    }

                    $relative = Get-NormalizedRelativePath -BasePath $fullPath -FullPath $file.FullName
                    $virtualPath = if ($relative) {
                        ([string]$definition.VirtualRoot).TrimEnd('/') + '/' + $relative
                    }
                    else {
                        [string]$definition.VirtualRoot
                    }

                    $inputFiles.Add([pscustomobject]@{
                        SourcePath = $file.FullName
                        Kind = 'direct'
                        VirtualPath = $virtualPath
                        HintPath = ''
                        SourceRelativePath = Get-NormalizedRelativePath -BasePath $packRoot -FullPath $file.FullName
                        Priority = [int]$definition.Priority
                    })
                }
            }

            'auto' {
                foreach ($mapping in $autoSortMappings) {
                    if ($null -eq $mapping) {
                        continue
                    }

                    $mappedFolder = Resolve-FullPath -BasePath $fullPath -Path ([string]$mapping.Folder)
                    if (-not (Test-Path -LiteralPath $mappedFolder)) {
                        continue
                    }

                    $files = Get-ChildItem -LiteralPath $mappedFolder -File -Recurse
                    foreach ($file in $files) {
                        if (Test-IgnoredSourceFile -Name $file.Name) {
                            continue
                        }

                        $relative = Get-NormalizedRelativePath -BasePath $mappedFolder -FullPath $file.FullName
                        $hintPath = [System.IO.Path]::GetDirectoryName($relative)
                        if ($hintPath) {
                            $hintPath = $hintPath -replace '\\', '/'
                        }
                        else {
                            $hintPath = ''
                        }

                        $inputFiles.Add([pscustomobject]@{
                            SourcePath = $file.FullName
                            Kind = 'auto'
                            VirtualPath = $file.Name
                            HintPath = $hintPath
                            AssetPrefix = [string]$mapping.AssetPrefix
                            CategoryFolder = [string]$mapping.Folder
                            SourceRelativePath = Get-NormalizedRelativePath -BasePath $packRoot -FullPath $file.FullName
                            Priority = [int]$definition.Priority
                        })
                    }
                }
            }
        }
    }

    return @($inputFiles | Sort-Object Priority, SourcePath)
}

function Assert-ValidJsonFile {
    param([Parameter(Mandatory = $true)][string]$Path)

    $raw = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
    $null = $raw | ConvertFrom-Json
}

function New-ZipFromDirectory {
    param(
        [Parameter(Mandatory = $true)][string]$SourceDirectory,
        [Parameter(Mandatory = $true)][string]$DestinationPath
    )

    if (Test-Path -LiteralPath $DestinationPath) {
        Remove-Item -LiteralPath $DestinationPath -Force
    }

    Add-Type -AssemblyName System.IO.Compression
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $archive = [System.IO.Compression.ZipFile]::Open($DestinationPath, [System.IO.Compression.ZipArchiveMode]::Create)
    try {
        foreach ($file in Get-ChildItem -LiteralPath $SourceDirectory -File -Recurse) {
            $entryPath = Get-NormalizedRelativePath -BasePath $SourceDirectory -FullPath $file.FullName
            $entry = $archive.CreateEntry($entryPath, [System.IO.Compression.CompressionLevel]::Optimal)
            $entryStream = $entry.Open()
            try {
                $fileStream = [System.IO.File]::OpenRead($file.FullName)
                try {
                    $fileStream.CopyTo($entryStream)
                }
                finally {
                    $fileStream.Dispose()
                }
            }
            finally {
                $entryStream.Dispose()
            }
        }
    }
    finally {
        $archive.Dispose()
    }
}

function Write-BuildReport {
    param(
        [Parameter(Mandatory = $true)][string]$ReportPath,
        [Parameter(Mandatory = $true)]$Report
    )

    Ensure-Directory -Path ([System.IO.Path]::GetDirectoryName($ReportPath))
    $json = $Report | ConvertTo-Json -Depth 100
    Set-Content -LiteralPath $ReportPath -Value $json -Encoding UTF8
}

function Build-PackVersion {
    param(
        [Parameter(Mandatory = $true)][string]$RepoRoot,
        [Parameter(Mandatory = $true)]$Config,
        [Parameter(Mandatory = $true)]$PackDirectory,
        [Parameter(Mandatory = $true)]$VersionConfig
    )

    if (-not $VersionConfig.Enabled) {
        return @{
            PackName = $PackDirectory.Name
            VersionId = $VersionConfig.Id
            Status = 'skipped'
            Reason = 'disabled'
        }
    }

    if ($VersionConfig.PackFormat -is [int] -or $VersionConfig.PackFormat -is [long]) {
        if ([int]$VersionConfig.PackFormat -le 0) {
            throw "Version '$($VersionConfig.Id)' is enabled but PackFormat is not set."
        }
    }

    $tokens = Get-PackTokens -Config $Config -PackDirectory $PackDirectory -VersionConfig $VersionConfig
    $buildRoot = Resolve-FullPath -BasePath $RepoRoot -Path ([string]$Config.BuildRoot)
    $zipRoot = Resolve-FullPath -BasePath $RepoRoot -Path ([string]$Config.ZipRoot)
    $reportRoot = Resolve-FullPath -BasePath $RepoRoot -Path ([string]$Config.ReportRoot)

    Ensure-Directory -Path $buildRoot
    Ensure-Directory -Path $zipRoot
    Ensure-Directory -Path $reportRoot

    $outputFolder = Join-Path -Path (Join-Path -Path $buildRoot -ChildPath $PackDirectory.Name) -ChildPath ([string]$VersionConfig.Id)
    $zipPackRoot = Join-Path -Path $zipRoot -ChildPath $PackDirectory.Name
    $packageBaseName = Convert-Tokens -Value ([string]$Config.PackageNameTemplate) -Tokens $tokens
    $zipPath = Join-Path -Path $zipPackRoot -ChildPath "$packageBaseName.zip"
    $reportPath = Join-Path -Path (Join-Path -Path $reportRoot -ChildPath $PackDirectory.Name) -ChildPath "$($VersionConfig.Id).json"

    if (Test-Path -LiteralPath $outputFolder) {
        Remove-Item -LiteralPath $outputFolder -Recurse -Force
    }
    if (Test-Path -LiteralPath $zipPath) {
        Remove-Item -LiteralPath $zipPath -Force
    }

    Ensure-Directory -Path $outputFolder
    Ensure-Directory -Path $zipPackRoot

    $inputFiles = Get-PackInputFiles -PackDirectory $PackDirectory -Config $Config -VersionConfig $VersionConfig
    $warnings = New-Object System.Collections.Generic.List[string]
    $destinations = @{}
    $catalog = $null
    $routeCache = Get-PackRouteCache -RepoRoot $RepoRoot -Config $Config -PackDirectory $PackDirectory -VersionConfig $VersionConfig
    $resolvedRouteCache = @{}
    $resolvedInputs = New-Object System.Collections.Generic.List[object]

    foreach ($inputFile in $inputFiles) {
        $resolvedPath = switch ($inputFile.Kind) {
            'root' { $inputFile.VirtualPath }
            'direct' { $inputFile.VirtualPath }
            'auto' {
                if ($null -eq $catalog) {
                    $catalog = Get-VanillaAssetCatalog -RepoRoot $RepoRoot -Config $Config -VersionConfig $VersionConfig
                }

                Resolve-AutoAssetPath -FileName $inputFile.VirtualPath -HintPath $inputFile.HintPath -AssetPrefix $inputFile.AssetPrefix -Catalog $catalog -CategoryFolder $inputFile.CategoryFolder -RouteCache $routeCache -RouteCacheKey $inputFile.SourceRelativePath
            }
            default {
                throw "Unknown input kind '$($inputFile.Kind)'."
            }
        }

        if ($resolvedPath -ne 'pack.png' -and $resolvedPath.StartsWith('assets/', [System.StringComparison]::OrdinalIgnoreCase)) {
            $resolvedPath = Get-TransformedPath -RelativePath $resolvedPath -VersionConfig $VersionConfig
            if ($null -eq $resolvedPath) {
                continue
            }
        }

        if ($inputFile.Kind -eq 'auto') {
            $resolvedRouteCache[$inputFile.SourceRelativePath] = $resolvedPath
        }

        if ($Config.Validation.RequireLowercasePaths -and $resolvedPath -cmatch '[A-Z]') {
            throw "Output path contains uppercase characters for pack '$($PackDirectory.Name)' version '$($VersionConfig.Id)': $resolvedPath"
        }

        if ($destinations.ContainsKey($resolvedPath)) {
            $existing = $destinations[$resolvedPath]
            if ([int]$inputFile.Priority -gt [int]$existing.Priority) {
                $warnings.Add("Overriding '$resolvedPath' with '$($inputFile.SourcePath)' over '$($existing.SourcePath)'")
                $destinations[$resolvedPath] = [pscustomobject]@{
                    SourcePath = $inputFile.SourcePath
                    Priority = [int]$inputFile.Priority
                }
            }
            elseif ([int]$inputFile.Priority -eq [int]$existing.Priority) {
                throw "Two source files resolve to the same output path for pack '$($PackDirectory.Name)' version '$($VersionConfig.Id)': $resolvedPath"
            }

            continue
        }

        $destinations[$resolvedPath] = [pscustomobject]@{
            SourcePath = $inputFile.SourcePath
            Priority = [int]$inputFile.Priority
        }

        $resolvedInputs.Add([pscustomobject]@{
            source = $inputFile.SourceRelativePath
            kind = $inputFile.Kind
            output = $resolvedPath
        })
    }

    foreach ($destPath in $destinations.Keys) {
        $fullDestPath = Resolve-FullPath -BasePath $outputFolder -Path $destPath
        Ensure-Directory -Path ([System.IO.Path]::GetDirectoryName($fullDestPath))
        Copy-Item -LiteralPath $destinations[$destPath].SourcePath -Destination $fullDestPath -Force
    }

    $mcmetaObject = New-PackMcmetaObject -Tokens $tokens -VersionConfig $VersionConfig
    $mcmetaJson = $mcmetaObject | ConvertTo-Json -Depth 100
    Set-Content -LiteralPath (Join-Path -Path $outputFolder -ChildPath 'pack.mcmeta') -Value $mcmetaJson -Encoding UTF8

    if ($Config.Validation.ParseJsonFiles) {
        foreach ($jsonFile in Get-ChildItem -LiteralPath $outputFolder -File -Recurse -Filter '*.json') {
            try {
                Assert-ValidJsonFile -Path $jsonFile.FullName
            }
            catch {
                throw "Invalid JSON in '$($jsonFile.FullName)': $($_.Exception.Message)"
            }
        }
    }

    if ($Config.Validation.ParseMcmetaFiles) {
        foreach ($mcmetaFile in Get-ChildItem -LiteralPath $outputFolder -File -Recurse -Filter '*.mcmeta') {
            try {
                Assert-ValidJsonFile -Path $mcmetaFile.FullName
            }
            catch {
                throw "Invalid mcmeta JSON in '$($mcmetaFile.FullName)': $($_.Exception.Message)"
            }
        }
    }

    if ($Config.Validation.RequireTextureForTextureMcmeta) {
        foreach ($mcmetaFile in Get-ChildItem -LiteralPath $outputFolder -File -Recurse -Filter '*.png.mcmeta') {
            $pngPath = $mcmetaFile.FullName.Substring(0, $mcmetaFile.FullName.Length - '.mcmeta'.Length)
            if (-not (Test-Path -LiteralPath $pngPath)) {
                throw "Texture metadata file is missing its texture pair: $($mcmetaFile.FullName)"
            }
        }
    }

    foreach ($requiredRule in @(Get-HashtableValueOrDefault -Table $VersionConfig -Key 'Required' -DefaultValue @())) {
        $matched = $false
        foreach ($builtPath in $destinations.Keys + @('pack.mcmeta')) {
            if (Test-RuleMatch -Path $builtPath -Rule ([string]$requiredRule)) {
                $matched = $true
                break
            }
        }

        if (-not $matched) {
            throw "Required output rule missing for pack '$($PackDirectory.Name)' version '$($VersionConfig.Id)': $requiredRule"
        }
    }

    New-ZipFromDirectory -SourceDirectory $outputFolder -DestinationPath $zipPath

    $builtFiles = @(Get-ChildItem -LiteralPath $outputFolder -File -Recurse | ForEach-Object {
        Get-NormalizedRelativePath -BasePath $outputFolder -FullPath $_.FullName
    } | Sort-Object)
    $warningItems = @($warnings | ForEach-Object { $_ })
    $resolvedInputItems = @($resolvedInputs | ForEach-Object { $_ })

    $report = [ordered]@{
        packName = $PackDirectory.Name
        versionId = [string]$VersionConfig.Id
        status = 'success'
        outputFolder = $outputFolder
        zipPath = $zipPath
        warnings = $warningItems
        resolvedInputs = $resolvedInputItems
        files = $builtFiles
    }
    Write-BuildReport -ReportPath $reportPath -Report $report
    Save-PackRouteCache -RepoRoot $RepoRoot -Config $Config -PackDirectory $PackDirectory -VersionConfig $VersionConfig -RouteCache $resolvedRouteCache

    return @{
        PackName = $PackDirectory.Name
        VersionId = [string]$VersionConfig.Id
        Status = 'success'
        OutputFolder = $outputFolder
        ZipPath = $zipPath
        ReportPath = $reportPath
        WarningCount = $warnings.Count
    }
}

$repoRoot = Split-Path -Path $PSScriptRoot -Parent
$configFullPath = Resolve-FullPath -BasePath $repoRoot -Path $ConfigPath
if (-not (Test-Path -LiteralPath $configFullPath)) {
    throw "Config file not found: $configFullPath"
}

$config = Import-PowerShellDataFile -Path $configFullPath

if ($config.ContainsKey('VersionMatrixPath') -and $config.VersionMatrixPath) {
    $versionMatrixPath = Resolve-FullPath -BasePath $repoRoot -Path ([string]$config.VersionMatrixPath)
    if (-not (Test-Path -LiteralPath $versionMatrixPath)) {
        throw "Version matrix file not found: $versionMatrixPath"
    }

    $versionMatrix = Import-PowerShellDataFile -Path $versionMatrixPath
    if (-not $versionMatrix.ContainsKey('Versions') -or @($versionMatrix.Versions).Count -eq 0) {
        throw "Version matrix file does not define any versions: $versionMatrixPath"
    }

    $config['Versions'] = @($versionMatrix.Versions | ForEach-Object { Normalize-VersionConfig -VersionConfig $_ })
}

if (-not $config.ContainsKey('Versions') -or @($config.Versions).Count -eq 0) {
    throw "No Minecraft versions are configured."
}

$config['Versions'] = @($config.Versions | ForEach-Object { Normalize-VersionConfig -VersionConfig $_ })

if ($ListVersions) {
    foreach ($entry in @($config.Versions)) {
        $state = if ($entry.Enabled) { 'enabled' } else { 'disabled' }
        Write-Output "$($entry.Id)`t$state`tpack_format=$(Format-PackFormatValue -Value $entry.PackFormat)"
    }
    exit 0
}

$packDirectories = Get-PackDirectories -RepoRoot $repoRoot -Config $config -RequestedPackNames $Pack

if ($ListPacks) {
    foreach ($packDirectory in $packDirectories) {
        Write-Output $packDirectory.Name
    }
    exit 0
}

$buildRoot = Resolve-FullPath -BasePath $repoRoot -Path ([string]$config.BuildRoot)
$zipRoot = Resolve-FullPath -BasePath $repoRoot -Path ([string]$config.ZipRoot)
$reportRoot = Resolve-FullPath -BasePath $repoRoot -Path ([string]$config.ReportRoot)
if ($Clean) {
    foreach ($path in @($buildRoot, $zipRoot, $reportRoot)) {
        if (Test-Path -LiteralPath $path) {
            Remove-Item -LiteralPath $path -Recurse -Force
        }
    }
}

$selectedVersions = @($config.Versions)
if ($Version) {
    $lookup = @{}
    foreach ($requested in $Version) {
        $lookup[$requested] = $true
    }

    $selectedVersions = @($config.Versions | Where-Object { $lookup.ContainsKey($_.Id) })
    if ($selectedVersions.Count -ne $lookup.Keys.Count) {
        $foundIds = @($selectedVersions | ForEach-Object { $_.Id })
        $missing = @($lookup.Keys | Where-Object { $_ -notin $foundIds })
        throw "Unknown version id(s): $($missing -join ', ')"
    }
}

$results = @()
$failures = New-Object System.Collections.Generic.List[string]

foreach ($packDirectory in $packDirectories) {
    $packSelectedVersions = Get-PackSelectedVersions -PackDirectory $packDirectory -Config $config -GloballySelectedVersions $selectedVersions
    foreach ($versionConfig in $packSelectedVersions) {
        try {
            $result = Build-PackVersion -RepoRoot $repoRoot -Config $config -PackDirectory $packDirectory -VersionConfig $versionConfig
            $results += ,$result
            if ($result.Status -eq 'success') {
                Write-Output "Built $($result.PackName) $($result.VersionId) -> $($result.ZipPath)"
            }
        }
        catch {
            $message = "Build failed for pack '$($packDirectory.Name)' version '$($versionConfig.Id)': $($_.Exception.Message)"
            $failures.Add($message)
            Write-Warning $message
        }
    }
}

if ($failures.Count -gt 0) {
    throw ($failures -join [Environment]::NewLine)
}
