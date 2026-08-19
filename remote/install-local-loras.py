#!/usr/bin/env python3
"""Safely stage, install, and verify project-local LoRA files."""

from __future__ import annotations

import hashlib
import json
import os
import pathlib
import shutil
import sys


def sha256_file(path: pathlib.Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def load_items(config_path: pathlib.Path) -> list[dict[str, object]]:
    with config_path.open("r", encoding="utf-8-sig") as stream:
        config = json.load(stream)
    items = config.get("anima", {}).get("local_loras", [])
    if not isinstance(items, list):
        raise ValueError("anima.local_loras must be an array")
    return items


def safe_destination(root: pathlib.Path, relative_text: str) -> pathlib.Path:
    relative = pathlib.PurePosixPath(relative_text)
    if relative.is_absolute() or not relative.parts or relative.suffix.lower() != ".safetensors":
        raise ValueError(f"unsafe local LoRA relative path: {relative_text!r}")
    if any(part in {"", ".", ".."} or any(ord(character) < 32 for character in part) for part in relative.parts):
        raise ValueError(f"unsafe local LoRA relative path: {relative_text!r}")
    destination = root.joinpath(*relative.parts).resolve()
    destination.relative_to(root)
    return destination


def validated_items(config_path: pathlib.Path, lora_root: pathlib.Path, staging_root: pathlib.Path):
    root = lora_root.resolve()
    stage = staging_root.resolve()
    seen_paths: set[str] = set()
    seen_ids: set[str] = set()
    for item in load_items(config_path):
        relative_path = str(item.get("relative_path", ""))
        expected_sha = str(item.get("sha256", "")).lower()
        staging_id = str(item.get("staging_id", "")).lower()
        size_bytes = item.get("size_bytes")
        if len(expected_sha) != 64 or any(character not in "0123456789abcdef" for character in expected_sha):
            raise ValueError(f"invalid SHA-256 for local LoRA {relative_path!r}")
        if len(staging_id) != 64 or any(character not in "0123456789abcdef" for character in staging_id):
            raise ValueError(f"invalid staging ID for local LoRA {relative_path!r}")
        if not isinstance(size_bytes, int) or size_bytes <= 0:
            raise ValueError(f"invalid size for local LoRA {relative_path!r}")
        destination = safe_destination(root, relative_path)
        path_key = str(destination).casefold()
        if path_key in seen_paths or staging_id in seen_ids:
            raise ValueError(f"duplicate local LoRA destination or staging ID: {relative_path!r}")
        seen_paths.add(path_key)
        seen_ids.add(staging_id)
        yield item, destination, stage / f"{staging_id}.part", stage / f"{staging_id}.ready"


def file_matches(path: pathlib.Path, expected_sha: str, expected_size: int) -> bool:
    return path.is_file() and path.stat().st_size == expected_size and sha256_file(path) == expected_sha


def check(config_path: pathlib.Path, lora_root: pathlib.Path, staging_root: pathlib.Path) -> None:
    staging_root.mkdir(parents=True, exist_ok=True)
    for item, destination, partial, ready in validated_items(config_path, lora_root, staging_root):
        expected_sha = str(item["sha256"])
        expected_size = int(item["size_bytes"])
        if file_matches(destination, expected_sha, expected_size):
            state = "installed"
        elif file_matches(ready, expected_sha, expected_size):
            state = "staged"
        else:
            partial.unlink(missing_ok=True)
            ready.unlink(missing_ok=True)
            state = "upload"
        print(f"{item['staging_id']}\t{state}")


def verify_stage(
    config_path: pathlib.Path, lora_root: pathlib.Path, staging_root: pathlib.Path, requested_id: str
) -> None:
    for item, _destination, partial, ready in validated_items(config_path, lora_root, staging_root):
        if item["staging_id"] != requested_id:
            continue
        if not file_matches(partial, str(item["sha256"]), int(item["size_bytes"])):
            raise ValueError(f"uploaded local LoRA failed size or SHA-256 verification: {item['relative_path']}")
        os.replace(partial, ready)
        print(f"ready\t{requested_id}")
        return
    raise ValueError(f"unknown local LoRA staging ID: {requested_id}")


def install(config_path: pathlib.Path, lora_root: pathlib.Path, staging_root: pathlib.Path) -> None:
    for item, destination, partial, ready in validated_items(config_path, lora_root, staging_root):
        expected_sha = str(item["sha256"])
        expected_size = int(item["size_bytes"])
        if file_matches(destination, expected_sha, expected_size):
            partial.unlink(missing_ok=True)
            ready.unlink(missing_ok=True)
            print(f"Already installed local LoRA: {item['relative_path']}")
            continue
        if not file_matches(ready, expected_sha, expected_size):
            raise ValueError(f"verified upload is missing for local LoRA: {item['relative_path']}")
        destination.parent.mkdir(parents=True, exist_ok=True)
        install_temp = destination.parent / f".{destination.name}.vast-anima-{item['staging_id']}.part"
        try:
            shutil.copyfile(ready, install_temp)
            if not file_matches(install_temp, expected_sha, expected_size):
                raise ValueError(f"local LoRA changed while copying into place: {item['relative_path']}")
            os.replace(install_temp, destination)
            ready.unlink()
        finally:
            install_temp.unlink(missing_ok=True)
        print(f"Installed local LoRA: {item['relative_path']}")


def verify(config_path: pathlib.Path, lora_root: pathlib.Path, staging_root: pathlib.Path) -> None:
    failures = []
    for item, destination, _partial, _ready in validated_items(config_path, lora_root, staging_root):
        if file_matches(destination, str(item["sha256"]), int(item["size_bytes"])):
            print(f"[OK] Local LoRA {item['relative_path']}")
        else:
            failures.append(str(item["relative_path"]))
            print(f"[MISSING] Local LoRA checksum {destination}", file=sys.stderr)
    if failures:
        raise SystemExit(20)


def main() -> None:
    if len(sys.argv) not in {5, 6}:
        raise SystemExit(
            "Usage: install-local-loras.py check|verify-stage|install|verify CONFIG LORA_ROOT STAGING_ROOT [STAGING_ID]"
        )
    command = sys.argv[1]
    config_path = pathlib.Path(sys.argv[2])
    lora_root = pathlib.Path(sys.argv[3])
    staging_root = pathlib.Path(sys.argv[4])
    if command == "check" and len(sys.argv) == 5:
        check(config_path, lora_root, staging_root)
    elif command == "verify-stage" and len(sys.argv) == 6:
        verify_stage(config_path, lora_root, staging_root, sys.argv[5])
    elif command == "install" and len(sys.argv) == 5:
        install(config_path, lora_root, staging_root)
    elif command == "verify" and len(sys.argv) == 5:
        verify(config_path, lora_root, staging_root)
    else:
        raise SystemExit(f"Invalid arguments for command: {command}")


if __name__ == "__main__":
    main()
