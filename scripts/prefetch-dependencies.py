#!/usr/bin/env python3
"""Fetch the pinned Ghostty manifests' remote archives over IPv4.

The manifests remain untouched. Zig computes each package hash from the local
archive and must agree with the checked-in manifest before the build proceeds.
"""

import os
from pathlib import Path
import re
import subprocess
import sys
from typing import Optional


ROOT = Path(__file__).resolve().parent.parent
ENGINE = ROOT / ".build" / "ghostty"
DOWNLOADS = ROOT / ".build" / "dependency-archives"
PIN = "982fe90d941e4b4aab4905ffcbcfdea60bd83343"


def run(*args: str, cwd: Optional[Path] = None) -> str:
    return subprocess.check_output(args, cwd=cwd, text=True, stderr=subprocess.PIPE).strip()


def main() -> None:
    if run("git", "rev-parse", "HEAD", cwd=ENGINE) != PIN:
        raise RuntimeError("Ghostty checkout does not match the pinned revision")

    if os.environ.get("ZIG_GLOBAL_CACHE_DIR"):
        cache = Path(os.environ["ZIG_GLOBAL_CACHE_DIR"]).resolve()
    else:
        env = run("zig", "env")
        match = re.search(r'\.global_cache_dir\s*=\s*"([^"]+)"', env)
        if not match:
            raise RuntimeError("could not determine Zig's global cache directory")
        cache = Path(match.group(1))

    dependencies: dict[str, str] = {}
    for manifest in sorted(ENGINE.rglob("build.zig.zon")):
        if ".zig-cache" in manifest.parts:
            continue
        pairs = re.findall(
            r'\.url\s*=\s*"([^"]+)"\s*,\s*\.hash\s*=\s*"([^"]+)"',
            manifest.read_text(),
        )
        for url, expected_hash in pairs:
            if url.startswith("https://"):
                if expected_hash in dependencies and dependencies[expected_hash] != url:
                    raise RuntimeError(f"conflicting URLs for package {expected_hash}")
                dependencies[expected_hash] = url

    DOWNLOADS.mkdir(parents=True, exist_ok=True)
    for expected_hash, url in sorted(dependencies.items()):
        if (cache / "p" / (expected_hash + ".tar.gz")).is_file():
            continue
        suffix = next((s for s in (".tar.zst", ".tar.xz", ".tar.gz", ".tgz") if url.endswith(s)), None)
        if suffix is None:
            raise RuntimeError(f"unsupported dependency archive: {url}")
        archive = DOWNLOADS / (expected_hash + suffix)
        if not archive.is_file():
            temporary = archive.with_name(archive.name + ".partial")
            temporary.unlink(missing_ok=True)
            print(f"Downloading {expected_hash} over IPv4", flush=True)
            subprocess.run(
                [
                    "curl", "-4", "--fail", "--location", "--silent", "--show-error",
                    "--retry", "2", "--connect-timeout", "10", "--max-time", "120",
                    "--output", str(temporary), url,
                ],
                check=True,
            )
            temporary.rename(archive)
        actual_hash = run(
            "zig", "fetch", "--global-cache-dir", str(cache), str(archive), cwd=ENGINE
        )
        if actual_hash != expected_hash:
            raise RuntimeError(f"Zig hash mismatch for {url}: expected {expected_hash}, got {actual_hash}")
        print(f"Verified {expected_hash}", flush=True)
    print(f"Dependency archives verified in Zig cache {cache}", flush=True)


if __name__ == "__main__":
    try:
        main()
    except (RuntimeError, subprocess.CalledProcessError, OSError) as error:
        print(f"prefetch-dependencies: {error}", file=sys.stderr)
        sys.exit(1)
