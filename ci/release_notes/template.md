# {product_title} v{version}

Pre-built **{product_title}** packages for Krate (Debian `.deb`, **amd64**).

## Features

- Pre-compiled binaries ready to install with `dpkg`
- JSON metadata alongside each `.deb` for automated catalog updates
- Built and published by GitHub Actions

## Available packages

{packages_table}

## Installation

1. Download the `.deb` for your slot (see table above).
2. Install: `sudo dpkg -i <package>.deb`
3. If needed: `sudo apt-get install -f`

Vendor apps install under `/opt/Krate/vendor/<family>_<version>`; dependency packages (Boost, libtorrent, …) use normal `dpkg` layout.

## Metadata

Each `.deb` is published with a matching `.json` sidecar, for example:

```json
{
  "package_id": "libboost-all-dev_1.88.0-1_amd64",
  "version": "1.88.0",
  "build": "1",
  "checksum_sha256": "<sha256>",
  "build_date": "2026-05-15T10:56:28Z",
  "category": "boost",
  "tag": "release",
  "type": "dev",
  "os": "trixie"
}
```

Fields: `package_id`, `version`, `build`, `checksum_sha256`, `build_date`, `category`, `tag`, `type`, and optionally `os`. Vendor binary packages (e.g. qBittorrent) may add extra keys such as `components` or `install_base`.

## License

{license}
