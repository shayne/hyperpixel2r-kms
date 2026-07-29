#!/usr/bin/env python3
"""Create, verify, and publish one immutable stable GitHub release draft."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import pathlib
import re
import subprocess
import sys
import tempfile
import urllib.parse
from typing import Any


REPOSITORY = "shayne/hyperpixel2r-kms"
REQUIRED_ASSETS = (
    "SHA256SUMS",
    "SBOM.spdx.json",
    "driver-manifest.json",
    "hyperpixel2r-kms-source.tar.zst",
)
MAX_ASSET_SIZE = 512 * 1024 * 1024
MAX_TOTAL_SIZE = 1024 * 1024 * 1024
STABLE_TAG = re.compile(r"^v[0-9]+\.[0-9]+\.[0-9]+$")
COMMIT = re.compile(r"^[0-9a-f]{40}$")
DIGEST = re.compile(r"^sha256:([0-9a-f]{64})$")


class ContractError(RuntimeError):
    """A stable-release precondition or immutable identity did not hold."""


def _require_identity(tag: str, commit: str) -> None:
    if not STABLE_TAG.fullmatch(tag):
        raise ContractError(f"stable tag is not canonical: {tag}")
    if not COMMIT.fullmatch(commit):
        raise ContractError("source commit must be a full lowercase SHA-1")


def _sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def _asset_inventory(release: dict[str, Any]) -> list[dict[str, Any]]:
    assets = release.get("assets")
    if not isinstance(assets, list):
        raise ContractError("release asset inventory is missing")
    inventory: list[dict[str, Any]] = []
    names: set[str] = set()
    total = 0
    for raw in assets:
        if not isinstance(raw, dict):
            raise ContractError("release asset entry is malformed")
        asset_id = raw.get("id")
        name = raw.get("name")
        size = raw.get("size")
        digest = raw.get("digest")
        if not isinstance(asset_id, int) or asset_id <= 0:
            raise ContractError("release asset ID is invalid")
        if not isinstance(name, str) or name not in REQUIRED_ASSETS or name in names:
            raise ContractError(f"release asset name is unexpected or duplicated: {name}")
        if not isinstance(size, int) or size <= 0 or size > MAX_ASSET_SIZE:
            raise ContractError(f"release asset size is invalid: {name}")
        if not isinstance(digest, str) or DIGEST.fullmatch(digest) is None:
            raise ContractError(f"release asset digest is missing or invalid: {name}")
        total += size
        if total > MAX_TOTAL_SIZE:
            raise ContractError("release assets exceed the total download limit")
        names.add(name)
        inventory.append(
            {"id": asset_id, "name": name, "size": size, "digest": digest}
        )
    if names != set(REQUIRED_ASSETS):
        missing = sorted(set(REQUIRED_ASSETS) - names)
        extra = sorted(names - set(REQUIRED_ASSETS))
        raise ContractError(f"release asset set differs: missing={missing} extra={extra}")
    return sorted(inventory, key=lambda item: item["name"])


def _asset_fingerprint(inventory: list[dict[str, Any]]) -> str:
    serialized = "".join(
        f"{item['id']}\t{item['name']}\t{item['size']}\t{item['digest']}\n"
        for item in inventory
    ).encode()
    return _sha256(serialized)


def _validate_draft_release(
    release: dict[str, Any],
    tag: str,
    commit: str,
    release_id: int,
    fingerprint: str | None = None,
) -> tuple[list[dict[str, Any]], str]:
    if release.get("id") != release_id:
        raise ContractError("draft release ID differs")
    if release.get("tag_name") != tag:
        raise ContractError("draft release tag name differs")
    if release.get("target_commitish") != commit:
        raise ContractError("draft release source commit differs")
    if release.get("draft") is not True or release.get("prerelease") is not False:
        raise ContractError("release is not the expected unpublished stable draft")
    inventory = _asset_inventory(release)
    actual = _asset_fingerprint(inventory)
    if fingerprint is not None and actual != fingerprint:
        raise ContractError("durable release asset identity fingerprint differs")
    return inventory, actual


def _validate_published_release(
    release: dict[str, Any],
    tag: str,
    commit: str,
    release_id: int,
    fingerprint: str,
) -> list[dict[str, Any]]:
    if (
        release.get("id") != release_id
        or release.get("tag_name") != tag
        or release.get("target_commitish") != commit
        or release.get("draft") is not False
        or release.get("prerelease") is not False
    ):
        raise ContractError("published stable release identity or state differs")
    inventory = _asset_inventory(release)
    if _asset_fingerprint(inventory) != fingerprint:
        raise ContractError("published stable release assets changed")
    return inventory


def _local_assets(directory: pathlib.Path) -> dict[str, bytes]:
    if not directory.is_dir() or directory.is_symlink():
        raise ContractError("release asset directory is missing or unsafe")
    entries = list(directory.iterdir())
    names = {entry.name for entry in entries}
    if names != set(REQUIRED_ASSETS):
        raise ContractError("local release asset set differs")
    result: dict[str, bytes] = {}
    total = 0
    for entry in entries:
        if entry.is_symlink() or not entry.is_file():
            raise ContractError(f"local release asset is not a regular file: {entry.name}")
        size = entry.stat().st_size
        if size <= 0 or size > MAX_ASSET_SIZE:
            raise ContractError(f"local release asset size is invalid: {entry.name}")
        total += size
        if total > MAX_TOTAL_SIZE:
            raise ContractError("local release assets exceed the total size limit")
        result[entry.name] = entry.read_bytes()
    return result


def _record(
    tag: str,
    commit: str,
    release_id: int,
    inventory: list[dict[str, Any]],
    fingerprint: str,
) -> dict[str, Any]:
    return {
        "schema_version": 1,
        "repository": REPOSITORY,
        "tag": tag,
        "commit": commit,
        "release_id": release_id,
        "asset_fingerprint": fingerprint,
        "assets": inventory,
    }


def _validate_record(record: dict[str, Any]) -> None:
    if record.get("schema_version") != 1 or record.get("repository") != REPOSITORY:
        raise ContractError("verification record schema or repository differs")
    tag = record.get("tag")
    commit = record.get("commit")
    release_id = record.get("release_id")
    fingerprint = record.get("asset_fingerprint")
    if not isinstance(tag, str) or not isinstance(commit, str):
        raise ContractError("verification record identity is missing")
    _require_identity(tag, commit)
    if not isinstance(release_id, int) or release_id <= 0:
        raise ContractError("verification record release ID is invalid")
    if not isinstance(fingerprint, str) or not re.fullmatch(r"[0-9a-f]{64}", fingerprint):
        raise ContractError("verification record fingerprint is invalid")
    inventory = record.get("assets")
    if not isinstance(inventory, list) or _asset_fingerprint(inventory) != fingerprint:
        raise ContractError("verification record asset inventory differs")


def create_stable_draft(
    backend: Any, tag: str, commit: str, assets_directory: pathlib.Path
) -> dict[str, Any]:
    _require_identity(tag, commit)
    if backend.tag_commit(tag) is not None:
        raise ContractError("stable tag already exists")
    local = _local_assets(assets_directory)
    release_id: int | None = None
    try:
        created = backend.create_release(tag, commit)
        release_id = created.get("id")
        if not isinstance(release_id, int) or release_id <= 0:
            raise ContractError("created draft release ID is invalid")
        if (
            created.get("tag_name") != tag
            or created.get("target_commitish") != commit
            or created.get("draft") is not True
            or created.get("prerelease") is not False
        ):
            raise ContractError("created release is not the requested stable draft")
        for name in sorted(local):
            uploaded = backend.upload_asset(release_id, name, local[name])
            if (
                uploaded.get("name") != name
                or uploaded.get("size") != len(local[name])
                or uploaded.get("digest") != f"sha256:{_sha256(local[name])}"
            ):
                raise ContractError(f"uploaded asset identity differs: {name}")
        release = backend.get_release(release_id)
        inventory, fingerprint = _validate_draft_release(
            release, tag, commit, release_id
        )
        if backend.tag_commit(tag) is not None:
            raise ContractError("stable tag appeared while draft assets were uploaded")
        return _record(tag, commit, release_id, inventory, fingerprint)
    except Exception:
        if release_id is not None:
            backend.delete_release(release_id)
        raise


def verify_stable_draft(
    backend: Any,
    tag: str,
    commit: str,
    release_id: int,
    fingerprint: str,
    downloads: pathlib.Path,
) -> dict[str, Any]:
    _require_identity(tag, commit)
    if backend.tag_commit(tag) is not None:
        raise ContractError("stable tag already exists")
    release = backend.get_release(release_id)
    inventory, actual = _validate_draft_release(
        release, tag, commit, release_id, fingerprint
    )
    if downloads.exists() or downloads.is_symlink():
        raise ContractError("stable verification download directory already exists")
    downloads.mkdir(mode=0o700, parents=True)
    try:
        for item in inventory:
            data = backend.download_asset(item["id"])
            if len(data) != item["size"] or f"sha256:{_sha256(data)}" != item["digest"]:
                raise ContractError(f"downloaded asset bytes differ: {item['name']}")
            path = downloads / item["name"]
            with path.open("xb") as output:
                output.write(data)
        local = _local_assets(downloads)
        for item in inventory:
            data = local[item["name"]]
            if len(data) != item["size"] or f"sha256:{_sha256(data)}" != item["digest"]:
                raise ContractError(f"local verified asset differs: {item['name']}")
    except Exception:
        for path in downloads.iterdir():
            if path.is_file() and not path.is_symlink():
                path.unlink()
        downloads.rmdir()
        raise
    return _record(tag, commit, release_id, inventory, actual)


def publish_verified_draft(
    backend: Any, verification_record: dict[str, Any], downloads: pathlib.Path
) -> dict[str, Any]:
    _validate_record(verification_record)
    tag = verification_record["tag"]
    commit = verification_record["commit"]
    release_id = verification_record["release_id"]
    fingerprint = verification_record["asset_fingerprint"]
    if backend.tag_commit(tag) is not None:
        raise ContractError("stable tag already exists")
    local = _local_assets(downloads)
    release = backend.get_release(release_id)
    inventory, actual = _validate_draft_release(
        release, tag, commit, release_id, fingerprint
    )
    for item in inventory:
        data = local[item["name"]]
        if len(data) != item["size"] or f"sha256:{_sha256(data)}" != item["digest"]:
            raise ContractError(f"accepted local asset differs: {item['name']}")
    if actual != fingerprint:
        raise ContractError("accepted stable draft fingerprint differs")

    backend.create_annotated_tag(tag, commit)
    if backend.tag_commit(tag) != commit:
        raise ContractError("published annotated tag does not dereference to source commit")
    try:
        published = backend.publish_release(release_id)
    except Exception as publish_error:
        try:
            observed = backend.get_release(release_id)
        except Exception as reread_error:
            raise ContractError(
                "release state is ambiguous after publication transport failure; "
                "the exact created tag was left in place"
            ) from reread_error
        try:
            published_inventory = _validate_published_release(
                observed, tag, commit, release_id, fingerprint
            )
        except ContractError:
            try:
                _validate_draft_release(
                    observed, tag, commit, release_id, fingerprint
                )
            except ContractError as drift_error:
                raise ContractError(
                    "release state drifted after publication failure; "
                    "the exact created tag was left in place"
                ) from drift_error
            backend.delete_annotated_tag(tag, commit)
            if backend.tag_commit(tag) is not None:
                raise ContractError("compensating stable tag deletion did not hold")
            raise ContractError(
                "stable publication failed; the exact created tag was removed for retry"
            ) from publish_error
    else:
        published_inventory = _validate_published_release(
            published, tag, commit, release_id, fingerprint
        )
    return _record(tag, commit, release_id, published_inventory, fingerprint)


class GhGitBackend:
    def __init__(self) -> None:
        self.gh = os.environ.get("HP2R_GH_BIN", "gh")
        self.git = os.environ.get("HP2R_GIT_BIN", "git")

    def _gh_json(
        self, arguments: list[str], input_data: bytes | None = None
    ) -> dict[str, Any]:
        result = subprocess.run(
            [self.gh, "api", *arguments],
            input=input_data,
            stdout=subprocess.PIPE,
            stderr=None,
            check=True,
        )
        value = json.loads(result.stdout)
        if not isinstance(value, dict):
            raise ContractError("GitHub API returned a non-object")
        return value

    def tag_commit(self, tag: str) -> str | None:
        local = subprocess.run(
            [self.git, "rev-parse", "--verify", "--quiet", f"refs/tags/{tag}^{{}}"],
            text=True,
            stdout=subprocess.PIPE,
            check=False,
        )
        if local.returncode == 0:
            return local.stdout.strip()
        remote = subprocess.run(
            [self.git, "ls-remote", "--tags", "origin", f"refs/tags/{tag}"],
            text=True,
            stdout=subprocess.PIPE,
            check=True,
        )
        if not remote.stdout.strip():
            return None
        subprocess.run(
            [
                self.git,
                "fetch",
                "--no-tags",
                "origin",
                f"refs/tags/{tag}:refs/tags/{tag}",
            ],
            check=True,
        )
        return subprocess.run(
            [self.git, "rev-parse", f"refs/tags/{tag}^{{}}"],
            text=True,
            stdout=subprocess.PIPE,
            check=True,
        ).stdout.strip()

    def create_release(self, tag: str, commit: str) -> dict[str, Any]:
        payload = json.dumps(
            {
                "tag_name": tag,
                "target_commitish": commit,
                "name": f"HyperPixel 2 Round KMS driver {tag}",
                "draft": True,
                "prerelease": False,
            },
            separators=(",", ":"),
        ).encode()
        return self._gh_json(
            ["--method", "POST", f"repos/{REPOSITORY}/releases", "--input", "-"],
            payload,
        )

    def delete_release(self, release_id: int) -> None:
        subprocess.run(
            [
                self.gh,
                "api",
                "--method",
                "DELETE",
                f"repos/{REPOSITORY}/releases/{release_id}",
            ],
            check=True,
        )

    def upload_asset(self, release_id: int, name: str, data: bytes) -> dict[str, Any]:
        endpoint = (
            f"repos/{REPOSITORY}/releases/{release_id}/assets"
            f"?name={urllib.parse.quote(name, safe='')}"
        )
        return self._gh_json(
            [
                "--method",
                "POST",
                "-H",
                "Content-Type: application/octet-stream",
                endpoint,
                "--input",
                "-",
            ],
            data,
        )

    def get_release(self, release_id: int) -> dict[str, Any]:
        return self._gh_json([f"repos/{REPOSITORY}/releases/{release_id}"])

    def download_asset(self, asset_id: int) -> bytes:
        return subprocess.run(
            [
                self.gh,
                "api",
                "-H",
                "Accept: application/octet-stream",
                f"repos/{REPOSITORY}/releases/assets/{asset_id}",
            ],
            stdout=subprocess.PIPE,
            check=True,
        ).stdout

    def create_annotated_tag(self, tag: str, commit: str) -> None:
        subprocess.run(
            [
                self.git,
                "tag",
                "--annotate",
                tag,
                commit,
                "--message",
                f"HyperPixel 2 Round KMS driver {tag}",
            ],
            check=True,
        )
        subprocess.run(
            [self.git, "push", "origin", f"refs/tags/{tag}:refs/tags/{tag}"],
            check=True,
        )

    def delete_annotated_tag(self, tag: str, commit: str) -> None:
        local_object = subprocess.run(
            [self.git, "rev-parse", f"refs/tags/{tag}"],
            text=True,
            stdout=subprocess.PIPE,
            check=True,
        ).stdout.strip()
        local_commit = subprocess.run(
            [self.git, "rev-parse", f"refs/tags/{tag}^{{}}"],
            text=True,
            stdout=subprocess.PIPE,
            check=True,
        ).stdout.strip()
        if local_commit != commit:
            raise ContractError("refusing to delete a different local stable tag")
        remote = subprocess.run(
            [self.git, "ls-remote", "--tags", "origin", f"refs/tags/{tag}"],
            text=True,
            stdout=subprocess.PIPE,
            check=True,
        ).stdout.strip().split()
        if len(remote) != 2 or remote[0] != local_object:
            raise ContractError("refusing to delete a different remote stable tag")
        subprocess.run(
            [
                self.git,
                "push",
                f"--force-with-lease=refs/tags/{tag}:{local_object}",
                "origin",
                f":refs/tags/{tag}",
            ],
            check=True,
        )
        subprocess.run([self.git, "tag", "--delete", tag], check=True)

    def publish_release(self, release_id: int) -> dict[str, Any]:
        payload = b'{"draft":false,"prerelease":false}'
        return self._gh_json(
            [
                "--method",
                "PATCH",
                f"repos/{REPOSITORY}/releases/{release_id}",
                "--input",
                "-",
            ],
            payload,
        )


def _write_record(path: pathlib.Path, record: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, temporary = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    try:
        os.fchmod(fd, 0o600)
        with os.fdopen(fd, "w") as output:
            json.dump(record, output, sort_keys=True, separators=(",", ":"))
            output.write("\n")
        os.replace(temporary, path)
    except Exception:
        os.close(fd)
        pathlib.Path(temporary).unlink(missing_ok=True)
        raise


def _read_record(path: pathlib.Path) -> dict[str, Any]:
    value = json.loads(path.read_text())
    if not isinstance(value, dict):
        raise ContractError("verification record is not an object")
    _validate_record(value)
    return value


def main() -> int:
    parser = argparse.ArgumentParser()
    commands = parser.add_subparsers(dest="command", required=True)
    draft = commands.add_parser("draft")
    draft.add_argument("--tag", required=True)
    draft.add_argument("--commit", required=True)
    draft.add_argument("--assets", type=pathlib.Path, required=True)
    draft.add_argument("--record", type=pathlib.Path, required=True)
    verify = commands.add_parser("verify")
    verify.add_argument("--tag", required=True)
    verify.add_argument("--commit", required=True)
    verify.add_argument("--release-id", type=int, required=True)
    verify.add_argument("--asset-fingerprint", required=True)
    verify.add_argument("--downloads", type=pathlib.Path, required=True)
    verify.add_argument("--record", type=pathlib.Path, required=True)
    publish = commands.add_parser("publish")
    publish.add_argument("--record", type=pathlib.Path, required=True)
    publish.add_argument("--downloads", type=pathlib.Path, required=True)
    args = parser.parse_args()
    backend = GhGitBackend()
    if args.command == "draft":
        record = create_stable_draft(backend, args.tag, args.commit, args.assets)
        _write_record(args.record, record)
    elif args.command == "verify":
        record = verify_stable_draft(
            backend,
            args.tag,
            args.commit,
            args.release_id,
            args.asset_fingerprint,
            args.downloads,
        )
        _write_record(args.record, record)
    else:
        record = publish_verified_draft(
            backend, _read_record(args.record), args.downloads
        )
    print(json.dumps(record, sort_keys=True, separators=(",", ":")))
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (ContractError, OSError, subprocess.CalledProcessError, json.JSONDecodeError) as error:
        print(f"stable release contract failed: {error}", file=sys.stderr)
        raise SystemExit(1)
