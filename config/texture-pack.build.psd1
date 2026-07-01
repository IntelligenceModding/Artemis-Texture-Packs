@{
    PackRoot = 'resource_packs'
    PackIconFile = 'pack.png'
    PackBuildConfigFile = 'pack.build.psd1'
    CanonicalAssetsFolder = 'assets'
    AutoSortFolder = 'drop'
    VersionMatrixPath = 'config/minecraft-release-version-matrix.psd1'
    AutoSortMappings = @(
        @{
            Folder = 'textures'
            AssetPrefix = 'assets/minecraft/textures/'
        }
        @{
            Folder = 'models'
            AssetPrefix = 'assets/minecraft/models/'
        }
        @{
            Folder = 'blockstates'
            AssetPrefix = 'assets/minecraft/blockstates/'
        }
        @{
            Folder = 'lang'
            AssetPrefix = 'assets/minecraft/lang/'
        }
        @{
            Folder = 'font'
            AssetPrefix = 'assets/minecraft/font/'
        }
        @{
            Folder = 'particles'
            AssetPrefix = 'assets/minecraft/particles/'
        }
        @{
            Folder = 'atlases'
            AssetPrefix = 'assets/minecraft/atlases/'
        }
        @{
            Folder = 'shaders'
            AssetPrefix = 'assets/minecraft/shaders/'
        }
        @{
            Folder = 'sounds'
            AssetPrefix = 'assets/minecraft/sounds/'
        }
        @{
            Folder = 'texts'
            AssetPrefix = 'assets/minecraft/texts/'
        }
    )

    BaseDescription = '{PackDisplayName} for Minecraft {VersionId}'
    BuildRoot = 'build'
    VanillaCatalogCacheRoot = 'cache/vanilla-asset-catalogs'
    MojangVersionManifestUrl = 'https://piston-meta.mojang.com/mc/game/version_manifest_v2.json'
    PackageNameTemplate = '{PackName}-{VersionId}'

    Validation = @{
        RequireLowercasePaths = $true
        ParseJsonFiles = $true
        ParseMcmetaFiles = $true
        RequireTextureForTextureMcmeta = $false
    }

    Versions = @()
}
