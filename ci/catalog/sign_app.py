#!/usr/bin/env python3
"""
Sign applications/CATALOG.json (or any catalog-shaped JSON) in place.

Re-uses used-tools/catalog/catalog_crypto.py:attach_signature so the
canonical JSON form is bit-for-bit identical to what `zenfw::catalog_canonical_utf8`
produces at verify time. The catalog public key embedded in zenfw is
`signing_purpose::applications` (see console/zenfw/src/modules/crypto/embedded_keys.cpp).

Behaviour:
  - If the input file already has a `signature` field — even an `UNSIGNED-...`
    placeholder from used-tools/catalog/app.py — it is stripped before
    signing. The placeholder is the expected dev/source-tree shape; the .deb
    release pipeline calls this script to swap it for a real RSA-SHA256 signature.
  - The private key is read from $KRATE_MANIFEST_PRIVATE_KEY (same env var
    used by used-tools/manifest/gen_manifest.py, so build-deb.sh can keep a single export
    pattern). Override with --private-key-env.
  - Output is sorted-keys + compact-separators + ascii-escaped, written with a
    trailing newline (matches catalog_crypto.attach_signature's canonicalization).

Usage:
    KRATE_MANIFEST_PRIVATE_KEY="$(cat applications.pem)" \\
        python3 used-tools/catalog/sign_app.py path/to/CATALOG.json

Exit codes:
  0  success
  1  missing/empty private key env
  2  input file not found / not readable
  3  input JSON malformed
  4  openssl signing failed
"""
from __future__ import annotations

import argparse
import json
import os
import sys
from pathlib import Path


def main() -> int:
    ap = argparse.ArgumentParser(description="Sign a KRATE applications CATALOG.json in place.")
    ap.add_argument("catalog", type=Path, help="Path to the CATALOG.json to sign")
    ap.add_argument(
        "--private-key-env",
        default="KRATE_MANIFEST_PRIVATE_KEY",
        help="Environment variable holding RSA PEM private key (default: KRATE_MANIFEST_PRIVATE_KEY).",
    )
    args = ap.parse_args()

    raw_key = (os.environ.get(args.private_key_env) or "").strip()
    if not raw_key:
        print(f"Missing or empty env {args.private_key_env}", file=sys.stderr)
        return 1

    if not args.catalog.is_file():
        print(f"Catalog file not found: {args.catalog}", file=sys.stderr)
        return 2

    try:
        catalog = json.loads(args.catalog.read_text(encoding="utf-8"))
    except json.JSONDecodeError as exc:
        print(f"Malformed JSON in {args.catalog}: {exc}", file=sys.stderr)
        return 3

    if not isinstance(catalog, dict):
        print(f"Catalog root is not a JSON object: {args.catalog}", file=sys.stderr)
        return 3

    catalog.pop("signature", None)

    catalog_dir = Path(__file__).resolve().parent
    if str(catalog_dir) not in sys.path:
        sys.path.insert(0, str(catalog_dir))
    from catalog_crypto import attach_signature  # type: ignore[import-not-found]

    try:
        attach_signature(catalog, raw_key)
    except Exception as exc:  # noqa: BLE001 — surface anything to the operator
        print(f"Signing failed: {exc}", file=sys.stderr)
        return 4

    out_txt = json.dumps(catalog, sort_keys=True, separators=(",", ":"), ensure_ascii=True)
    args.catalog.write_text(out_txt + "\n", encoding="utf-8")
    print(f"Signed {args.catalog} ({len(catalog.get('apps', []))} apps)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
