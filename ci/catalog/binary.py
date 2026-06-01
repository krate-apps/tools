#!/usr/bin/env python3
"""
Build BINARIES_CATALOG.json from GitHub Releases (see used-tools/README.md and binaries/snapshots/README.md).

Requires: gh, dpkg-deb. Optional: openssl (signing). Repo rules: edit DEFAULT_RULES in this file.
"""
from __future__ import annotations

import argparse
import fnmatch
import hashlib
import json
import os
import re
import subprocess
import sys
import tempfile
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path

DEFAULT_RULES: list[dict[str, str]] = [
    {"repo": "krate-binaries/deluge-builds", "family": "deluge", "deb_glob": "krate-deluge_*_amd64.deb"},
    {"repo": "krate-binaries/qBittorrent-builds", "family": "qbittorrent-nox", "deb_glob": "krate-qbittorrent_*_amd64.deb"},
    {"repo": "krate-binaries/rtorrent-builds", "family": "rtorrent", "deb_glob": "krate-rtorrent_*_amd64.deb"},
    {"repo": "krate-binaries/transmission-builds", "family": "transmission-daemon", "deb_glob": "krate-transmission_*_amd64.deb"},
]


def sha256_file(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def run(cmd: list[str], cwd: Path | None = None, env: dict | None = None) -> None:
    subprocess.run(cmd, cwd=cwd, check=True, env=env)


def gh_env() -> dict[str, str]:
    e = os.environ.copy()
    if "GH_TOKEN" not in e and e.get("GITHUB_TOKEN"):
        e["GH_TOKEN"] = e["GITHUB_TOKEN"]
    return e


def gh_api_json(path: str, env: dict[str, str]) -> list | dict:
    out = subprocess.check_output(["gh", "api", "-H", "Accept: application/vnd.github+json", path], env=env, text=True)
    return json.loads(out)


def list_releases(repo: str, env: dict[str, str]) -> list[dict]:
    """All releases (paginated)."""
    all_rel: list[dict] = []
    page = 1
    while True:
        chunk = gh_api_json(f"repos/{repo}/releases?per_page=100&page={page}", env)
        if not chunk:
            break
        all_rel.extend(chunk)
        if len(chunk) < 100:
            break
        page += 1
    return all_rel


def infer_install_base(deb_path: Path) -> str:
    """Unpack .deb and read /opt/Krate/vendor/<one dir> if present."""
    try:
        with tempfile.TemporaryDirectory(prefix="me-deb-") as td:
            td_path = Path(td)
            run(["dpkg-deb", "-x", str(deb_path), str(td_path)])
            vendor = td_path / "opt" / "KRATE" / "vendor"
            if not vendor.is_dir():
                return ""
            subs = [p for p in vendor.iterdir() if p.is_dir()]
            if len(subs) == 1:
                return "/opt/Krate/vendor/" + subs[0].name
    except (subprocess.CalledProcessError, OSError):
        return ""
    return ""


def slot_and_version(family: str, deb_name: str) -> tuple[str, str]:
    """
    Return (slot_id, version) for catalog row.
    slot_id is what users pass to `zen binary select -s`; version is used for ordering / display.
    """
    base = deb_name
    if base.endswith(".deb"):
        base = base[:-4]

    if family == "qbittorrent-nox":
        m = re.match(r"krate-qbittorrent_(.+)_lt_(.+)-(\d+)_amd64$", base)
        if m:
            ver = f"{m.group(1)}_lt_{m.group(2)}"
            slot = f"{m.group(1)}-lt-{m.group(2)}"
            return slot, ver
    if family == "deluge":
        m = re.match(r"krate-deluge_(.+)-(\d+)_amd64$", base)
        if m:
            return m.group(1), m.group(1)
    if family == "transmission-daemon":
        m = re.match(r"krate-transmission_(.+)-(\d+)_amd64$", base)
        if m:
            return m.group(1), m.group(1)
    if family == "rtorrent":
        m = re.match(r"krate-rtorrent_(.+)-(\d+)_amd64$", base)
        if m:
            return m.group(1), m.group(1)
    if family == "boost":
        m = re.match(r"libboost-all-dev_(.+)-(\d+)_amd64$", base)
        if m:
            return m.group(1), m.group(1)

    # fallback: strip common suffix
    return base.replace("_amd64", "").replace("-1", ""), base


@dataclass
class Discovered:
    family: str
    repo: str
    tag: str
    deb_name: str
    published_at: str
    slot: str
    version: str


def discover_all(rules: list[dict[str, str]], env: dict[str, str]) -> list[Discovered]:
    out: list[Discovered] = []
    seen_names: set[str] = set()

    for rule in rules:
        repo = rule["repo"]
        family = rule["family"]
        glob_pat = rule["deb_glob"]
        releases = list_releases(repo, env)
        releases.sort(key=lambda r: r.get("published_at") or "", reverse=True)

        for rel in releases:
            if rel.get("draft"):
                continue
            tag = rel.get("tag_name") or ""
            published = rel.get("published_at") or ""
            for asset in rel.get("assets") or []:
                name = asset.get("name") or ""
                if not name.endswith(".deb"):
                    continue
                if not fnmatch.fnmatch(name, glob_pat):
                    continue
                if name in seen_names:
                    continue
                seen_names.add(name)
                slot, version = slot_and_version(family, name)
                out.append(
                    Discovered(
                        family=family,
                        repo=repo,
                        tag=tag,
                        deb_name=name,
                        published_at=published,
                        slot=slot,
                        version=version,
                    )
                )
    return out


def main() -> int:
    parser = argparse.ArgumentParser(description="Build BINARIES_CATALOG.json from GitHub releases (automated scan)")
    parser.add_argument("--out", type=Path, default=Path("BINARIES_CATALOG.json"))
    parser.add_argument(
        "--snapshots-repo",
        default=os.environ.get("SNAPSHOTS_REPO", "krate-binaries/snapshots"),
        help="This repo (owner/name); used in deb_url",
    )
    parser.add_argument("--snapshot-tag", default=os.environ.get("SNAPSHOT_TAG", ""), help="Release tag on snapshots repo, e.g. snapshot-20260510")
    parser.add_argument("--snapshot-id", default=os.environ.get("SNAPSHOT_ID", ""), help="Catalog snapshot_id field (e.g. 20260510)")
    parser.add_argument("--os", default=os.environ.get("CATALOG_OS", "debian-13"))
    parser.add_argument("--copy-debs-to", type=Path, default=None)
    parser.add_argument(
        "--private-key-file",
        type=Path,
        default=None,
        help="PEM private key for signing; alternatively env BINARIES_CATALOG_SIGNING_PRIVATE_KEY (preferred) or CATALOG_SIGNING_PRIVATE_KEY",
    )
    parser.add_argument(
        "--signing-key-id",
        default=os.environ.get("SIGNING_KEY_ID", ""),
        help="Optional signing_key_id field (included in signed payload before signature)",
    )
    args = parser.parse_args()

    if not args.snapshot_tag:
        print("SNAPSHOT_TAG or --snapshot-tag is required", file=sys.stderr)
        return 2
    if not args.snapshot_id:
        print("SNAPSHOT_ID or --snapshot-id is required", file=sys.stderr)
        return 2

    env = gh_env()
    discovered = discover_all(DEFAULT_RULES, env)
    if not discovered:
        print("No matching .deb assets found on configured repos.", file=sys.stderr)
        return 1

    by_family: dict[str, list[Discovered]] = {}
    for d in discovered:
        by_family.setdefault(d.family, []).append(d)

    families_json: list[dict] = []
    generated = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

    with tempfile.TemporaryDirectory(prefix="me-catdl-") as tmp:
        tmp_path = Path(tmp)
        for family_id in sorted(by_family.keys()):
            rows = by_family[family_id]
            default_slot = ""
            if rows:
                best = max(rows, key=lambda x: x.published_at or "")
                default_slot = best.slot

            slots_out: list[dict] = []
            for d in sorted(rows, key=lambda x: (x.slot, x.version)):
                dest_dir = tmp_path / family_id / d.slot
                dest_dir.mkdir(parents=True, exist_ok=True)
                run(
                    [
                        "gh",
                        "release",
                        "download",
                        d.tag,
                        "--repo",
                        d.repo,
                        "--pattern",
                        d.deb_name,
                        "--dir",
                        str(dest_dir),
                    ],
                    env=env,
                )
                deb_path = dest_dir / d.deb_name
                if not deb_path.is_file():
                    print(f"Missing after download: {deb_path}", file=sys.stderr)
                    return 1
                digest = sha256_file(deb_path)
                install_base = infer_install_base(deb_path)
                if not install_base:
                    install_base = f"/opt/Krate/vendor/{family_id}_{d.version}"

                deb_url = (
                    f"https://github.com/{args.snapshots_repo}/releases/download/{args.snapshot_tag}/{d.deb_name}"
                )

                if args.copy_debs_to is not None:
                    args.copy_debs_to.mkdir(parents=True, exist_ok=True)
                    (args.copy_debs_to / d.deb_name).write_bytes(deb_path.read_bytes())

                slots_out.append(
                    {
                        "slot": d.slot,
                        "version": d.version,
                        "deb_url": deb_url,
                        "sha256": digest,
                        "install_base": install_base,
                        "deb_filenames": [d.deb_name],
                    }
                )

            families_json.append({"id": family_id, "default_slot": default_slot, "slots": slots_out})

    catalog: dict[str, object] = {
        "schema_version": 1,
        "generated_at": generated,
        "snapshot_id": args.snapshot_id,
        "os": args.os,
        "families": families_json,
    }

    if args.signing_key_id:
        catalog["signing_key_id"] = args.signing_key_id

    signing_pem = (
        (os.environ.get("BINARIES_CATALOG_SIGNING_PRIVATE_KEY") or "").strip()
        or (os.environ.get("CATALOG_SIGNING_PRIVATE_KEY") or "").strip()
    )
    if args.private_key_file is not None:
        signing_pem = args.private_key_file.read_text(encoding="utf-8")
    if signing_pem:
        scripts_dir = str(Path(__file__).resolve().parent)
        if scripts_dir not in sys.path:
            sys.path.insert(0, scripts_dir)
        from catalog_crypto import attach_signature

        attach_signature(catalog, signing_pem)

    args.out.write_text(json.dumps(catalog, indent=2), encoding="utf-8")
    print(f"Wrote {args.out} ({len(families_json)} families)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
