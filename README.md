# Artemis Texture Pack Builder

This repository now builds texture packs from folders under `resource_packs/`.

## Top-level structure

```text
resource_packs/   source packs you edit
scripts/          build, scaffold, and matrix-sync scripts
config/           builder config plus generated Minecraft release matrix
build/            generated completed packs, zips, and reports
cache/            cached Mojang asset catalogs and remembered route maps
.github/          CI workflow
```

Each folder inside `resource_packs/` is one source pack. The folder name becomes the pack name for output files and the default in-game description.

## Pack layout

Example:

```text
resource_packs/
  alternative_birch_leaves/
    pack.png
    assets/
      minecraft/
        textures/
        models/
    drop/
```

For your current pack, the builder reads:

- `resource_packs/alternative_birch_leaves/pack.png`
- `resource_packs/alternative_birch_leaves/drop/**`
- `resource_packs/alternative_birch_leaves/pack.build.psd1`

and leaves those source files untouched.

## Two input modes

### 1. Canonical assets

Put files under `assets/...` when you already know the exact target path.

Example:

```text
resource_packs/alternative_birch_leaves/assets/minecraft/textures/block/birch_leaves.png
```

The builder copies that into the finished pack and then applies version-specific rewrites like `block -> blocks` for old Minecraft versions.

### 2. Typed auto-sort uploads

Put files into typed subfolders under `drop/` when you want the project to figure out the vanilla target path automatically.

Example:

```text
resource_packs/alternative_birch_leaves/drop/textures/block/birch_leaves.png
resource_packs/alternative_birch_leaves/drop/textures/item/stone_pickaxe.png
resource_packs/alternative_birch_leaves/drop/models/block/birch_leaves.json
resource_packs/alternative_birch_leaves/drop/models/item/stone_pickaxe.json
resource_packs/alternative_birch_leaves/drop/blockstates/birch_leaves.json
```

Available typed drop folders:

- `drop/textures/`
- `drop/models/`
- `drop/blockstates/`
- `drop/lang/`
- `drop/font/`
- `drop/particles/`
- `drop/atlases/`
- `drop/shaders/`
- `drop/sounds/`
- `drop/texts/`

Recommended subfolders where the asset class splits by purpose:

- `drop/textures/block/`
- `drop/textures/item/`
- `drop/models/block/`
- `drop/models/item/`

The builder downloads or reuses an official Mojang asset catalog per Minecraft version, narrows the lookup by typed folder, and places the file into the correct `assets/...` path in the generated output.

It also remembers the resolved output path of each dropped source file per pack and per Minecraft version under:

- `cache/vanilla-asset-catalogs/resolved-pack-routes/<pack>/<version>.json`

Notes:

- `pack.png` is never sorted into `assets/minecraft`; it stays at the resource-pack root.
- For textures and models, prefer the `block/` or `item/` subfolders from the start.
- You can still add deeper subfolders as extra hints, such as `drop/textures/entity/` or `drop/models/gui/`, when Minecraft uses them.
- If a filename is still ambiguous inside the selected asset class, the build fails and tells you which target paths matched. In that case, either add a more specific subfolder hint or place that file under `assets/...` yourself.
- `assets/...` remains the fallback for anything custom or unclear.

## Per-pack version selection

Each pack can decide which Minecraft versions it should build by adding:

```text
resource_packs/<pack>/pack.build.psd1
```

Example:

```powershell
@{
    MinVersion = '1.13'
}
```

That means the pack will be generated for every configured release version from `1.13` upward.

You can also exclude versions instead:

```powershell
@{
    ExcludeVersions = @(
        '1.12.2'
    )
}
```

You can also select version ranges based on the order of versions in the global config.

Inclusive range:

```powershell
@{
    MinVersion = '1.16.5'
    MaxVersion = '1.20.4'
}
```

Exclusive range:

```powershell
@{
    AfterVersion = '1.12.2'
    BeforeVersion = '1.21.9'
}
```

Rules:

- `Versions` is an allow-list for that pack
- `ExcludeVersions` removes versions for that pack
- `MinVersion` and `MaxVersion` are inclusive bounds
- `AfterVersion` and `BeforeVersion` are exclusive bounds
- range comparison uses the order of `Versions` in the global [config/texture-pack.build.psd1](/C:/Users/grego/IdeaProjects/Artemis-Texture-Packs/config/texture-pack.build.psd1)
- if the file does not exist, the pack uses all globally enabled versions
- CLI selection still applies first, then the pack-local filter is applied on top

## Output

The builder generates:

- `build/completed/<pack>/<version>/`
- `build/zips/<pack>/<pack>-<version>.zip`
- `build/reports/<pack>/<version>.json`

Each build report also records which source file resolved to which output path.

## Full release matrix

The global version list is generated into:

- `config/minecraft-release-version-matrix.psd1`

That file currently covers every official release version after `1.12.2`, from `1.13` through `26.2`, and the main config loads it automatically.

## `pack.mcmeta` compatibility handling

The builder supports Mojang's current pack metadata breakpoints:

- up to `1.20.1`: `pack_format` only
- `1.20.2` through `1.21.8`: integer `pack_format` plus optional `supported_formats`
- `1.21.9` and newer: `pack_format` as `major`/`minor`, plus optional `supported_formats`

The default config emits exact-match compatibility ranges for versions that support `supported_formats`, so the generated pack metadata stays aligned with the target version unless you widen the range yourself.

## Local build

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\build-texture-packs.ps1
```

## IntelliJ run targets

This repo now includes shared IntelliJ run configurations under `.run/`.

In IntelliJ, use the run-config dropdown at the top right and select:

- `Build All Texture Packs`
- `Create New Texture Pack`

`Build All Texture Packs` runs the full builder in the IntelliJ terminal.

`Create New Texture Pack` starts the scaffold script and prompts for the pack name in the IntelliJ terminal.

## Create a new pack

In IntelliJ, run `Create New Texture Pack`, enter the pack name, and the repo will create the full folder scaffold under `resource_packs/`.

It creates:

- `pack.build.psd1`
- `assets/minecraft/`
- `drop/textures/block/`
- `drop/textures/item/`
- `drop/models/block/`
- `drop/models/item/`
- the other typed `drop/` folders

You can also run it directly:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\new-texture-pack.ps1 -Name stone_tools -MinVersion 1.13
```

If you still want a Windows launcher outside IntelliJ, [Build All Texture Packs.cmd](/C:/Users/grego/IdeaProjects/Artemis-Texture-Packs/Build%20All%20Texture%20Packs.cmd) runs the same build script.

Useful commands:

```powershell
# list available packs
powershell -ExecutionPolicy Bypass -File .\scripts\build-texture-packs.ps1 -ListPacks

# list configured versions
powershell -ExecutionPolicy Bypass -File .\scripts\build-texture-packs.ps1 -ListVersions

# build one pack
powershell -ExecutionPolicy Bypass -File .\scripts\build-texture-packs.ps1 -Pack alternative_birch_leaves

# build one pack for selected versions
powershell -ExecutionPolicy Bypass -Command "& '.\scripts\build-texture-packs.ps1' -Pack alternative_birch_leaves -Version @('1.13','1.20.4','26.2')"

# remove generated output and rebuild
powershell -ExecutionPolicy Bypass -File .\scripts\build-texture-packs.ps1 -Clean
```

## GitHub Actions

The workflow at [.github/workflows/build-packs.yml](/C:/Users/grego/IdeaProjects/Artemis-Texture-Packs/.github/workflows/build-packs.yml) builds packs automatically when pack sources, config, or scripts change.

## Current source pack

Your first pack is here:

- [resource_packs/alternative_birch_leaves](/C:/Users/grego/IdeaProjects/Artemis-Texture-Packs/resource_packs/alternative_birch_leaves)

Its current asset files are in typed `drop/...` folders, and the builder now resolves them automatically for every release version from `1.13` through `26.2`.
