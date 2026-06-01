#!/usr/bin/env python3
"""
Build applications/CATALOG.json from applications/**/meta.yaml + manifest.yaml.

Official apps get dev placeholder bundle fields (replace at release/signing time).
"""
from __future__ import annotations

import argparse
import json
import sys
from datetime import datetime, timezone
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[2]
APPS = ROOT / "applications"
OUT = APPS / "CATALOG.json"
SCHEMA = ROOT / "ai" / "docs" / "ecommerce" / "schemas" / "catalog.schema.json"

LINK_FALLBACK = "https://krate.github.io/docs/"
# Valid 64-hex placeholder until CI injects real bundle hashes
PLACEHOLDER_SHA256 = "0" * 64
LOCAL_LOGO_EXTS = (".png", ".webp", ".jpg", ".jpeg", ".gif", ".svg")


def load_yaml(path: Path) -> dict:
    if not path.is_file():
        return {}
    data = yaml.safe_load(path.read_text(encoding="utf-8"))
    return data if isinstance(data, dict) else {}


def normalize_links(raw: dict) -> dict:
    hp = raw.get("homepage") or raw.get("documentation") or raw.get("source") or LINK_FALLBACK
    doc = raw.get("documentation") or hp
    src = raw.get("source") or hp
    out: dict = {"homepage": str(hp), "documentation": str(doc), "source": str(src)}
    med = raw.get("krate_docs")
    if med:
        out["krate_docs"] = str(med)
    return out


def discover(kind: str, base: Path) -> list[tuple[str, Path]]:
    if not base.is_dir():
        return []
    out: list[tuple[str, Path]] = []
    for child in sorted(base.iterdir()):
        if child.is_dir() and (child / "meta.yaml").is_file():
            out.append((kind, child))
    return out


def local_logo_path(kind: str, app_dir: Path, app_id: str) -> str:
    """
    Resolve the catalog `logo` path for an app.

    Convention: every app ships `${app_id}.png` next to its `meta.yaml`. Even when the file is not
    yet committed, we emit the deterministic path `/applications/{kind}/{app}/{app_id}.png`; the API
    controller transparently falls back to the shipped brand default on miss. Existing files with a
    different basename (`logo.png`, etc.) are still detected and preferred for backward compat.
    """
    deployed_kind = "official" if kind == "official" else "community"
    canonical = f"/applications/{deployed_kind}/{app_dir.name}/{app_id}.png"

    for ext in LOCAL_LOGO_EXTS:
        candidate = app_dir / f"{app_id}{ext}"
        if candidate.is_file():
            return f"/applications/{deployed_kind}/{app_dir.name}/{candidate.name}"

    for ext in LOCAL_LOGO_EXTS:
        candidate = app_dir / f"logo{ext}"
        if candidate.is_file():
            return f"/applications/{deployed_kind}/{app_dir.name}/{candidate.name}"

    if app_dir.is_dir():
        images = sorted(p for p in app_dir.iterdir() if p.is_file() and p.suffix.lower() in LOCAL_LOGO_EXTS)
        if images:
            return f"/applications/{deployed_kind}/{app_dir.name}/{images[0].name}"

    return canonical


def build_app(kind: str, app_dir: Path) -> dict:
    meta = load_yaml(app_dir / "meta.yaml")
    manifest = load_yaml(app_dir / "manifest.yaml")

    app_id = str(meta.get("id") or app_dir.name)
    name = str(meta.get("name") or app_id)
    tier = str(meta.get("tier") or "free")
    if tier not in ("free", "pro"):
        tier = "free"
    install_mode = str(meta.get("install_mode") or "remote")
    if install_mode not in ("local", "remote"):
        install_mode = "remote"

    opts = meta.get("autocomplete_options")
    if not isinstance(opts, list):
        opts = []
    options = [str(x) for x in opts if isinstance(x, str) and x.strip()]

    category = str(meta.get("category") or "general")
    desc = str(meta.get("description") or f"{name} application.")
    logo = local_logo_path(kind, app_dir, app_id)

    links = normalize_links(meta.get("links") if isinstance(meta.get("links"), dict) else {})

    entry: dict = {
        "id": app_id,
        "name": name,
        "type": "official" if kind == "official" else "community",
        "category": category,
        "tier": tier,
        "install_mode": install_mode,
        "options": options,
        "description": desc,
        "logo": logo,
        "links": links,
    }

    mu = manifest.get("multi_user")
    if isinstance(mu, bool):
        entry["multi_user"] = mu

    ag = manifest.get("autogen")
    if isinstance(ag, list) and ag:
        entry["autogen"] = [str(x) for x in ag if isinstance(x, str)]

    uio = meta.get("ui_options")
    if isinstance(uio, dict) and uio:
        entry["ui_options"] = uio

    if kind == "official":
        entry["bundle_url"] = f"https://cdn.krate.io/bundles/official/{app_id}/latest.tar.gz"
        entry["bundle_sha256"] = PLACEHOLDER_SHA256
        entry["bundle_signature"] = "UNSIGNED-PLACEHOLDER-REGENERATE-IN-RELEASE-PIPELINE"

    return entry


def validate(doc: dict) -> None:
    try:
        import jsonschema
    except ImportError:
        print("warning: jsonschema not installed; skip schema validation", file=sys.stderr)
        return
    schema = json.loads(SCHEMA.read_text(encoding="utf-8"))
    jsonschema.validate(instance=doc, schema=schema)


def main() -> int:
    parser = argparse.ArgumentParser(description="Generate applications/CATALOG.json from meta + manifest.")
    parser.add_argument(
        "--output",
        type=Path,
        default=OUT,
        help=f"Output path (default: {OUT})",
    )
    parser.add_argument(
        "--no-validate",
        action="store_true",
        help="Skip JSON Schema validation",
    )
    args = parser.parse_args()

    pairs: list[tuple[str, Path]] = []
    pairs.extend(discover("official", APPS / "official-apps"))
    pairs.extend(discover("community", APPS / "community-apps"))
    if not pairs:
        # Packaged layout under /opt/Krate/share/applications
        pairs.extend(discover("official", APPS / "official"))
        pairs.extend(discover("community", APPS / "community"))

    apps = [build_app(kind, d) for kind, d in pairs]
    apps.sort(key=lambda a: a["id"])

    doc = {
        "generated_at": datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z"),
        "schema_version": 1,
        "apps": apps,
        "signature": "UNSIGNED-GENERATED-CATALOG-REGENERATE-IN-RELEASE-PIPELINE",
    }

    if not args.no_validate:
        validate(doc)

    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(doc, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    print(f"Wrote {args.output} ({len(apps)} apps)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
