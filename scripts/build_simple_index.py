"""Generate a PEP 503 'simple' index for the bpy wheels.

PEP 503 layout (served from /simple/):
  simple/index.html         -- root, links to /simple/bpy/
  simple/bpy/index.html     -- one <a href=...> per wheel

Each wheel link is `<filename>#sha256=<hex>` pointing at the GitHub
Release asset URL. Pip uses the trailing fragment to verify the
download.

This script regenerates simple/ from a list of wheel files (with
their hex sha256s and release URLs). Stdlib only; suitable to run
on any GHA runner.

Usage:
    python build_simple_index.py <out_dir> <manifest.json>

manifest.json schema:
    [{"filename": "bpy-5.1.1-cp313-cp313-win_amd64.whl",
      "sha256":   "<hex>",
      "url":      "https://github.com/.../releases/download/.../bpy-...whl"},
     ...]
"""
from __future__ import annotations

import html
import json
import sys
from pathlib import Path


ROOT_TEMPLATE = """<!DOCTYPE html>
<html><head><meta charset="utf-8"><title>bpy-conda simple index</title></head>
<body>
<h1>bpy-conda — pip simple index</h1>
<p>PEP 503 index for <a href="https://github.com/PozzettiAndrea/bpy-conda">bpy-conda</a>'s wheels.</p>
<p>Install:</p>
<pre>pip install --index-url https://pozzettiandrea.github.io/bpy-conda/simple/ bpy</pre>
<ul>
<li><a href="bpy/">bpy/</a></li>
</ul>
</body></html>
"""


PROJECT_TEMPLATE = """<!DOCTYPE html>
<html><head><meta charset="utf-8"><title>Links for bpy</title></head>
<body>
<h1>Links for bpy</h1>
{links}
</body></html>
"""


def main() -> int:
    if len(sys.argv) != 3:
        print("usage: build_simple_index.py <out_dir> <manifest.json>", file=sys.stderr)
        return 2

    out_dir = Path(sys.argv[1]).resolve()
    manifest_path = Path(sys.argv[2]).resolve()

    manifest = json.loads(manifest_path.read_text())
    if not isinstance(manifest, list):
        print("manifest must be a JSON array", file=sys.stderr)
        return 1

    simple = out_dir / "simple"
    bpy_dir = simple / "bpy"
    bpy_dir.mkdir(parents=True, exist_ok=True)

    (simple / "index.html").write_text(ROOT_TEMPLATE, encoding="utf-8")

    # Sort by filename so the page is stable and diff-friendly.
    manifest.sort(key=lambda e: e["filename"])

    link_lines = []
    for entry in manifest:
        fn = entry["filename"]
        url = entry["url"]
        sha = entry["sha256"]
        # PEP 503 hash fragment is hex sha256 (NOT base64 like wheel RECORD).
        link_lines.append(
            f'<a href="{html.escape(url)}#sha256={sha}">{html.escape(fn)}</a><br>'
        )
    project_html = PROJECT_TEMPLATE.format(links="\n".join(link_lines))
    (bpy_dir / "index.html").write_text(project_html, encoding="utf-8")

    # Top-level README so visitors to the bare GitHub Pages URL get something
    # useful instead of a 404.
    (out_dir / "index.html").write_text(
        '<!DOCTYPE html><html><head><meta charset="utf-8">'
        '<title>bpy-conda</title>'
        '<meta http-equiv="refresh" content="0;url=simple/">'
        "</head><body>Redirecting to <a href=\"simple/\">simple/</a></body></html>\n",
        encoding="utf-8",
    )

    print(f"wrote {simple / 'index.html'}")
    print(f"wrote {bpy_dir / 'index.html'}  ({len(manifest)} wheels)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
