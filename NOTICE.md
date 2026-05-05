# Attribution & GPL source availability

Blender is © Blender Foundation and contributors, distributed under the GNU General Public License v2.0 or later (GPL-2.0-or-later). The full license text is in [LICENSE](LICENSE).

The `bpy` Python module built by this repository is a derivative of Blender. Per Section 3 of GPL-2.0, this repository functions as the "corresponding source" obligation for the binaries published to the `pozzettiandrea` anaconda.org channel:

- The Blender source revision is pinned per build in [`packages/bpy.yml`](packages/bpy.yml) under `source_tag`. Every published `bpy` package corresponds to the value of `source_tag` at the commit recorded in the package's build metadata.
- The build configuration (CMake flags, environment, variant matrix) is in [`recipes/bpy/`](recipes/bpy/).
- For any binary distributed via the channel, anyone may obtain the matching source by checking out this repository at the commit referenced in the package and reading `packages/bpy.yml`, then cloning Blender at that tag from <https://projects.blender.org/blender/blender>.

## Trademark

"Blender" is a trademark of the Blender Foundation. This repository and the resulting conda packages are not endorsed by, affiliated with, or sponsored by the Blender Foundation. The package is named `bpy` (the upstream Python module name); no claim is made that these builds are "official."

## Upstream

- Blender source: <https://projects.blender.org/blender/blender>
- Blender Foundation: <https://www.blender.org/>
- Official `bpy` wheels (Python 3.11, 3.13 only at time of writing): <https://pypi.org/project/bpy/>
