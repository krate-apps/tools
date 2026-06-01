#!/usr/bin/env python3
"""
Canonical JSON + RSA-SHA256 signing for BINARIES_CATALOG.json.

Signed message = UTF-8 bytes of:
  json.dumps(catalog_without_signature, sort_keys=True, separators=(',', ':'), ensure_ascii=True)
"""
from __future__ import annotations

import argparse
import base64
import json
import os
import subprocess
import sys
import tempfile
from pathlib import Path


def normalize_pem_secret(pem: str, *, kind: str) -> str:
    """
    Repair a PEM coming from a GitHub Secret / env: BOM, surrounding quotes,
    literal \\n, CRLF. kind ('private'|'public') is only for error messages.
    """
    if pem is None or not str(pem).strip():
        raise ValueError(f"PEM is empty ({kind})")
    s = str(pem).strip().lstrip("\ufeff")
    if len(s) >= 2 and s[0] == s[-1] and s[0] in "\"'":
        s = s[1:-1].strip()
    if "\\n" in s:
        s = s.replace("\\r\\n", "\n").replace("\\n", "\n")
    s = s.replace("\r\n", "\n").replace("\r", "\n")
    if "-----BEGIN" not in s or "-----END" not in s:
        raise ValueError(f"PEM ({kind}) is missing BEGIN/END markers — paste the full key, multiline")
    if not s.endswith("\n"):
        s += "\n"
    return s


def canonical_catalog_json(catalog: dict[str, object]) -> str:
    """Must stay aligned with zenfw::catalog_canonical_utf8 (sorted keys at every object)."""
    return json.dumps(catalog, sort_keys=True, separators=(",", ":"), ensure_ascii=True)


def sign_sha256_openssl(private_key_pem: str, message_utf8: bytes) -> str:
    """Return base64-encoded RSA-SHA256 signature."""
    pem = normalize_pem_secret(private_key_pem, kind="private")
    with tempfile.TemporaryDirectory(prefix="me-cat-sign-") as td:
        base = Path(td)
        key_path = base / "key.pem"
        msg_path = base / "msg.bin"
        sig_path = base / "sig.bin"
        with key_path.open("w", encoding="utf-8", newline="\n") as kf:
            kf.write(pem)
        os.chmod(key_path, 0o600)
        msg_path.write_bytes(message_utf8)

        r = subprocess.run(
            ["openssl", "dgst", "-sha256", "-sign", str(key_path), "-out", str(sig_path), str(msg_path)],
            capture_output=True,
            text=True,
        )
        if r.returncode != 0:
            err = (r.stderr or r.stdout or "").strip()
            raise RuntimeError(
                "openssl dgst -sign failed. " + err
            )
        return base64.b64encode(sig_path.read_bytes()).decode("ascii")


def attach_signature(catalog: dict[str, object], private_key_pem: str) -> None:
    """Mutates catalog: adds base64 signature over the JSON without the signature field."""
    if "signature" in catalog:
        raise ValueError("catalog must not contain signature before signing")
    canon = canonical_catalog_json(catalog).encode("utf-8")
    catalog["signature"] = sign_sha256_openssl(private_key_pem, canon)


def verify_catalog_file(catalog_path: Path, public_key_pem: str) -> bool:
    """Verify with `openssl dgst -sha256 -verify` (matches zenfw)."""
    obj = json.loads(catalog_path.read_text(encoding="utf-8"))
    sig_b64 = obj.pop("signature", None)
    if not isinstance(sig_b64, str) or not sig_b64:
        print("No signature field", file=sys.stderr)
        return False
    canon = canonical_catalog_json(obj).encode("utf-8")
    sig_raw = base64.b64decode(sig_b64, validate=True)
    with tempfile.TemporaryDirectory(prefix="me-cat-vfy-") as td:
        base = Path(td)
        pub_path = base / "pub.pem"
        msg_path = base / "msg.bin"
        sig_path = base / "sig.bin"
        with pub_path.open("w", encoding="utf-8", newline="\n") as pf:
            pf.write(normalize_pem_secret(public_key_pem, kind="public"))
        msg_path.write_bytes(canon)
        sig_path.write_bytes(sig_raw)
        r = subprocess.run(
            ["openssl", "dgst", "-sha256", "-verify", str(pub_path), "-signature", str(sig_path), str(msg_path)],
            capture_output=True,
            text=True,
        )
    if r.returncode != 0:
        print(r.stdout or "", r.stderr or "", file=sys.stderr)
        return False
    return True


def main() -> int:
    p = argparse.ArgumentParser(description="Verify BINARIES_CATALOG.json signature (offline check).")
    p.add_argument("catalog", type=Path)
    p.add_argument("--public-key", type=Path, required=True)
    args = p.parse_args()
    pem = args.public_key.read_text(encoding="utf-8")
    if verify_catalog_file(args.catalog, pem):
        print("OK")
        return 0
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
