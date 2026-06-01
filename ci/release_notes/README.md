# Binary release notes (CI)

Shared generator for GitHub release bodies in `krate-binaries/*-builds` repos.

## Table format

| Package | Version | Arch |
| ------- | ------- | ---- |

- **Package**: `.deb` filename (download asset name).
- **Version**: upstream version; for `_lt_<libtorrent>` builds, shown as `5.2.0 (libtorrent 2.0.12)`.
- **Arch**: e.g. `amd64`.

## Layouts

- **standard** — one release = one upstream version, one or more `.deb` rows (rtorrent, transmission, boost, rasterbar).
- **multivariant** — same upstream version, several builds (qBittorrent, Deluge): sections per libtorrent version.

## CI usage

After copying assets into `release_assets/`:

```bash
pip3 install --upgrade pyyaml
python3 tools/ci/release_notes.py \
  --product rtorrent \
  --version "0.16.11" \
  --assets-dir release_assets \
  --github-output
```

Then `body: ${{ steps.prepare.outputs.release_body }}` and `generate_release_notes: false`.

Product keys: `products.yaml`.
