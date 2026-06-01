#!/usr/bin/env python3
"""
Generate Krate binary release notes: packages table (Package | Version | Arch) and full body.

Usage (CI):
  python3 tools/ci/release_notes.py \\
    --product rtorrent \\
    --version 0.16.11 \\
    --assets-dir release_assets \\
    --output-table "$GITHUB_OUTPUT" \\
    --output-body release_body.md

Products: see release_notes/products.yaml
"""
from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path
from typing import Any

try:
    import yaml
except ImportError:
    yaml = None  # type: ignore

# name_<version>[_lt_<libtorrent>]-<rev>_<arch>.deb
DEB_RE = re.compile(
    r"^(?P<name>.+?)_(?P<ver>\d+(?:\.\d+)*)"
    r"(?:_lt_(?P<lt>\d+(?:\.\d+)*))?"
    r"-(?P<rev>\d+)_(?P<arch>[a-z0-9]+)\.deb$",
    re.IGNORECASE,
)

HERE = Path(__file__).resolve().parent
PRODUCTS_FILE = HERE / "release_notes" / "products.yaml"
TEMPLATE_FILE = HERE / "release_notes" / "template.md"


def load_products() -> dict[str, Any]:
    if yaml is None:
        raise SystemExit("PyYAML required: pip install pyyaml")
    if not PRODUCTS_FILE.is_file():
        raise SystemExit(f"Missing products config: {PRODUCTS_FILE}")
    data = yaml.safe_load(PRODUCTS_FILE.read_text(encoding="utf-8")) or {}
    if not isinstance(data, dict):
        raise SystemExit("Invalid products.yaml")
    return data


def parse_deb_filename(filename: str) -> dict[str, str]:
    m = DEB_RE.match(filename)
    if not m:
        return {
            "package": filename.removesuffix(".deb"),
            "version": "",
            "arch": "",
            "variant": "",
            "filename": filename,
        }
    ver = m.group("ver")
    lt = m.group("lt") or ""
    version_display = f"{ver} (libtorrent {lt})" if lt else ver
    return {
        "package": m.group("name"),
        "version": version_display,
        "arch": m.group("arch"),
        "variant": lt,
        "filename": filename,
    }


def table_header() -> str:
    return "| Package | Version | Arch |\n| ------- | ------- | ---- |\n"


def table_row(row: dict[str, str]) -> str:
    pkg_cell = f"`{row['filename']}`"
    ver = row["version"] or "—"
    arch = row["arch"] or "—"
    return f"| {pkg_cell} | {ver} | {arch} |\n"


def version_sort_key(s: str) -> list[int]:
    parts: list[int] = []
    for piece in s.split("."):
        num = ""
        for ch in piece:
            if ch.isdigit():
                num += ch
            else:
                break
        parts.append(int(num) if num else 0)
    return parts


def build_standard_table(deb_paths: list[Path]) -> str:
    rows = [parse_deb_filename(p.name) for p in sorted(deb_paths, key=lambda p: p.name)]
    out = table_header()
    for row in rows:
        out += table_row(row)
    return out


def build_multivariant_table(
    deb_paths: list[Path], variant_label: str = "libtorrent"
) -> str:
    from collections import defaultdict

    by_variant: dict[str, list[dict[str, str]]] = defaultdict(list)
    other: list[dict[str, str]] = []
    for p in deb_paths:
        row = parse_deb_filename(p.name)
        if row["variant"]:
            by_variant[row["variant"]].append(row)
        else:
            other.append(row)

    out = ""
    intro = (
        f"This release ships **{len(deb_paths)}** package(s) for the same upstream version, "
        f"built against different **{variant_label}** versions.\n\n"
    )
    out += intro

    for variant in sorted(by_variant.keys(), key=version_sort_key):
        out += f"### {variant_label} {variant}\n\n"
        out += table_header()
        for row in sorted(by_variant[variant], key=lambda r: r["filename"]):
            out += table_row(row)
        out += "\n"

    if other:
        out += "### Other packages\n\n"
        out += table_header()
        for row in sorted(other, key=lambda r: r["filename"]):
            out += table_row(row)
        out += "\n"

    return out


def build_packages_table(
    deb_paths: list[Path], product_cfg: dict[str, Any]
) -> str:
    layout = product_cfg.get("layout", "standard")
    if layout == "multivariant":
        return build_multivariant_table(
            deb_paths, product_cfg.get("variant_label", "libtorrent")
        )
    return build_standard_table(deb_paths)


def render_body(
    product_cfg: dict[str, Any], version: str, packages_table: str
) -> str:
    """Substitute known placeholders only (template may contain JSON with `{` `}`)."""
    tpl = TEMPLATE_FILE.read_text(encoding="utf-8")
    title = product_cfg.get("title", "Package")
    license_block = (product_cfg.get("license") or "").strip()
    replacements = {
        "{product_title}": title,
        "{version}": version,
        "{packages_table}": packages_table.strip(),
        "{license}": license_block,
    }
    body = tpl
    for placeholder, value in replacements.items():
        body = body.replace(placeholder, value)
    return body


def append_github_output(key: str, value: str) -> None:
    import os

    out_path = os.environ.get("GITHUB_OUTPUT")
    if not out_path:
        raise SystemExit("GITHUB_OUTPUT is not set")
    delimiter = f"RN_{key}"
    with open(out_path, "a", encoding="utf-8") as fh:
        fh.write(f"{key}<<{delimiter}\n")
        fh.write(value)
        if value and not value.endswith("\n"):
            fh.write("\n")
        fh.write(f"{delimiter}\n")


def write_text_target(path: str, content: str) -> None:
    if path in ("-", "/dev/stdout"):
        sys.stdout.write(content)
        if content and not content.endswith("\n"):
            sys.stdout.write("\n")
        return
    Path(path).write_text(content, encoding="utf-8")


def main() -> int:
    ap = argparse.ArgumentParser(description="Krate binary release notes generator")
    ap.add_argument("--product", required=True, help="Product key in products.yaml")
    ap.add_argument("--version", required=True, help="Upstream release version (tag without v)")
    ap.add_argument("--assets-dir", required=True, type=Path, help="Directory containing .deb files")
    ap.add_argument("--output-table", default="", help="Write packages table to this file (or -)")
    ap.add_argument("--output-body", default="", help="Write full release body to this file (or -)")
    ap.add_argument(
        "--github-output",
        action="store_true",
        help="Also set packages_table and release_body on GITHUB_OUTPUT",
    )
    args = ap.parse_args()

    products = load_products()
    product_cfg = products.get(args.product)
    if not product_cfg:
        raise SystemExit(f"Unknown product {args.product!r}; keys: {', '.join(sorted(products))}")

    deb_paths = sorted(args.assets_dir.glob("*.deb"))
    if args.version:
        needle = f"_{args.version}"
        deb_paths = [p for p in deb_paths if needle in p.name]
    if not deb_paths:
        print("::warning::No .deb files in assets dir", file=sys.stderr)

    packages_table = build_packages_table(deb_paths, product_cfg)
    body = render_body(product_cfg, args.version, packages_table)

    if args.output_table:
        write_text_target(args.output_table, packages_table)
    if args.output_body:
        write_text_target(args.output_body, body)
    if args.github_output:
        append_github_output("packages_table", packages_table)
        append_github_output("release_body", body)

    if not args.output_table and not args.output_body and not args.github_output:
        print(body)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
