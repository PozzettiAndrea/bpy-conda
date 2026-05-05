# bpy-conda

Conda packages for Blender's [`bpy`](https://docs.blender.org/api/current/) Python module, built from source with `rattler-build` and published to anaconda.org.

The official `bpy` wheels on PyPI are only published for a subset of Python versions (currently 3.11 and 3.13). This channel fills the gaps (3.10, 3.12, 3.14) and ships a single, conda-installable artifact per `(blender, python, platform)` combo.

## Channel

```
https://conda.anaconda.org/pozzettiandrea
```

## Install

```bash
conda install -c conda-forge -c pozzettiandrea bpy
```

Or with pixi:

```toml
[project]
channels = ["conda-forge", "https://conda.anaconda.org/pozzettiandrea"]

[dependencies]
bpy = "*"
```

## Build matrix

| | |
|---|---|
| Blender | 4.2 LTS (`v4.2.20`) |
| Python | 3.10, 3.11, 3.12, 3.13, 3.14 |
| Platforms | linux-64, win-64, osx-arm64 |

Adding more Blender versions: append to `packages/bpy.yml` and re-run the workflow.

## Build locally

```bash
rattler-build build \
  --recipe recipes/bpy/recipe.yaml \
  --variant-config variants.yaml \
  --variant python=3.12 \
  --variant blender_version=4.2.20 \
  --channel conda-forge
```

## Trigger CI build

```bash
# Single cell (validate first):
gh workflow run build.yml -f python=3.12 -f platform=linux

# Full matrix:
gh workflow run build.yml
```

## License & GPL compliance

Blender — and therefore `bpy` — is licensed under [GPL-2.0-or-later](LICENSE). This repository is itself the source-availability artifact required by the GPL: every published binary on the channel was built from the exact tag pinned in `packages/bpy.yml` at the recipe revision linked from the commit history. See [NOTICE.md](NOTICE.md) for upstream attribution.

This is an unofficial community build. Not affiliated with or endorsed by the Blender Foundation.
