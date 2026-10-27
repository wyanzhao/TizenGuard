#!/usr/bin/env python3
"""Stage the unsigned TizenGuard widget tree, verify integrity, and run tests."""

from __future__ import annotations

import argparse
import glob
import hashlib
import json
import re
import shutil
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

FORBIDDEN_REGEXES = [
    re.compile(r"/Users/[A-Za-z0-9._-]+"),
    re.compile(r"\b192\.168\.\d{1,3}\.\d{1,3}\b"),
    re.compile(r"BEGIN (?:RSA |EC )?PRIVATE KEY"),
]

# SHA-256 digests of lowercase internal/temporary development identifiers.
FORBIDDEN_TOKEN_HASHES = {
    "57de4cf40144bdf7d00010f2f5557a7d642c2b9705309bfade167dd313e2ca93",
    "12205573eeb3019dfdd06d43becd71ba57a26c3ca614c57adb5bf4e7f8b87a21",
    "f3bc466d7a3172222cb4ff44ad364b22ae790cefa58cbcc80cd0ed29f6748c3a",
    "610f3c1e36d9a474a6fcf8e1b1d15c6dace5e32557dca84a39a3c138bb94aedd",
    "552005325c6984c17f79dbfab8eac55e2d0e52776479b29630aac5f8a45c9189",
    "c3f29928a6d11fab7e2f7663e875372f423738e02493563b25dc57b113cb3320",
    "647a09dda9e1f4cf377938ef2811dcd36074eec39ca12c44a9bafb030bc71f44",
    "d26bd47d4e0135372ea58f4218e7232740e8c81378c1be6f22aceaf06a38d8db",
    "500fd7696635819dfad4c8573cd290773ddac1e0642dd12f66d967a5c63216d0",
    "5c7997d9c25d857a7e0c683db248aede78602d08459ba78ad4d8a8f00065be70",
    "e2ba0bcd5b4fe1d966f611c84aed8f31b01687d88c5c4afb3d3e254f25032a24",
    "f1fd5e9211336dacc8c153406c6dea83d16819a07b1bdb0c177dc4a938c7bf38",
    "da59e7d5be9e4e0ffda46db16acf70e4739205a69de7d65720744a8dc8b2d077",
}

TOKEN_SPLIT_RE = re.compile(r"[A-Za-z0-9_-]{4,}")

SHELL_SCRIPTS = [
    "policies/boot-policy.sh",
    "policies/restore-optional-app.sh",
    "tools/provision-on-tv.sh",
    "widget/service/check-policy.sh",
]


def sha256_file(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def verify_shell_syntax() -> None:
    for rel in SHELL_SCRIPTS:
        subprocess.run(["bash", "-n", str(ROOT / rel)], check=True)


def verify_payload_manifest() -> None:
    payload_dir = ROOT / "widget" / "payload"
    manifest = json.loads((payload_dir / "manifest.json").read_text(encoding="utf-8"))
    if not isinstance(manifest, dict) or len(manifest) != 6:
        raise SystemExit(f"Invalid payload manifest entry count: {len(manifest) if isinstance(manifest, dict) else 0}")
    for name, expected_sha in manifest.items():
        actual_sha = sha256_file(payload_dir / name)
        if actual_sha != expected_sha:
            raise SystemExit(
                f"Payload manifest mismatch for {name}: expected {expected_sha}, got {actual_sha}"
            )


def check_text_clean(text: str, rel: Path) -> None:
    for rx in FORBIDDEN_REGEXES:
        m = rx.search(text)
        if m:
            raise SystemExit(f"Forbidden pattern {m.group(0)!r} found in {rel}")
    for word in set(TOKEN_SPLIT_RE.findall(text.lower())):
        if hashlib.sha256(word.encode("utf-8")).hexdigest() in FORBIDDEN_TOKEN_HASHES:
            raise SystemExit(f"Forbidden internal token {word!r} found in {rel}")


def scan_forbidden_tokens() -> None:
    scan_dirs = ["widget", "policies", "helpers", "tools", "test", "docs", ".github"]
    candidates: list[Path] = []
    for d in scan_dirs:
        base = ROOT / d
        if base.exists():
            candidates.extend(p for p in base.rglob("*") if p.is_file())
    for top in ("README.md", "AGENTS.md", "LICENSE", ".gitignore"):
        p = ROOT / top
        if p.exists():
            candidates.append(p)

    for path in sorted(set(candidates)):
        rel = path.relative_to(ROOT)
        raw = path.read_bytes()
        check_text_clean(raw.decode("utf-8", errors="replace"), rel)
        if path.suffix == ".dll":
            check_text_clean(raw.decode("utf-16le", errors="replace"), rel)


def stage_widget(out_dir: Path) -> dict[str, object]:
    wgt_dir = out_dir / "wgt"
    if out_dir.exists():
        shutil.rmtree(out_dir)
    shutil.copytree(ROOT / "widget", wgt_dir)

    members = {}
    for file_path in sorted(p for p in wgt_dir.rglob("*") if p.is_file()):
        rel = file_path.relative_to(wgt_dir).as_posix()
        members[rel] = {
            "bytes": file_path.stat().st_size,
            "sha256": sha256_file(file_path),
        }

    summary = {
        "package_id": "TizenGuard",
        "service_id": "TizenGuard.Service",
        "app_id": "TizenGuard.App",
        "policy_sha256": sha256_file(ROOT / "policies" / "boot-policy.sh"),
        "members": members,
    }
    (out_dir / "package-members.json").write_text(
        json.dumps(summary, indent=2) + "\n", encoding="utf-8"
    )
    return summary


def run_tests() -> None:
    test_files = sorted(glob.glob(str(ROOT / "test" / "*.test.cjs")))
    if not test_files:
        raise SystemExit("No test files found in test/")
    subprocess.run(["node", "--test", *test_files], cwd=ROOT, check=True)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--out", default="build", help="Build output directory")
    parser.add_argument("--no-test", action="store_true", help="Skip Node test suite")
    args = parser.parse_args()

    verify_shell_syntax()
    verify_payload_manifest()
    scan_forbidden_tokens()
    summary = stage_widget(ROOT / args.out)
    if not args.no_test:
        run_tests()
    print(json.dumps(summary, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
