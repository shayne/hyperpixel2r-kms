#!/usr/bin/env python3
"""Hostile, stateful simulations of stable draft creation and promotion."""

from __future__ import annotations

import copy
import hashlib
import importlib.util
import inspect
import json
import os
import pathlib
import tempfile


ROOT = pathlib.Path(__file__).resolve().parents[1]
MODULE_PATH = ROOT / "scripts" / "stable_release.py"
SPEC = importlib.util.spec_from_file_location("stable_release", MODULE_PATH)
if SPEC is None or SPEC.loader is None:
    raise SystemExit("cannot load scripts/stable_release.py")
stable_release = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(stable_release)
download_source = inspect.getsource(stable_release.GhGitBackend.download_asset)
assert "stdout=subprocess.PIPE" not in download_source
assert "RLIMIT_FSIZE" in download_source
assert "O_EXCL" in download_source

TAG = "v0.1.0"
COMMIT = "a" * 40


class FakeBackend:
    def __init__(self) -> None:
        self.release: dict | None = None
        self.asset_bytes: dict[int, bytes] = {}
        self.remote_tags: dict[str, tuple[str, str]] = {}
        self.local_tags: dict[str, tuple[str, str]] = {}
        self.upload_count = 0
        self.build_count = 0
        self.patch_payloads: list[dict] = []
        self.next_asset_id = 100
        self.push_mode = "success"
        self.patch_mode = "success"
        self.partial_asset: int | None = None
        self.extra_asset: int | None = None
        self.download_limits: list[tuple[int, int]] = []

    def remote_tag(self, tag: str) -> dict | None:
        value = self.remote_tags.get(tag)
        if value is None:
            return None
        return {"object": value[0], "commit": value[1]}

    def create_release(self, tag: str, commit: str) -> dict:
        if self.release is not None:
            raise stable_release.ContractError("release already exists")
        self.release = {
            "id": 42,
            "tag_name": tag,
            "target_commitish": commit,
            "draft": True,
            "prerelease": False,
            "assets": [],
        }
        return copy.deepcopy(self.release)

    def delete_release(self, release_id: int) -> None:
        if self.release and self.release["id"] == release_id:
            self.release = None
            self.asset_bytes.clear()

    def upload_asset(self, release_id: int, name: str, path: pathlib.Path) -> dict:
        assert self.release and self.release["id"] == release_id
        data = path.read_bytes()
        self.upload_count += 1
        asset = {
            "id": self.next_asset_id,
            "name": name,
            "size": len(data),
            "digest": f"sha256:{hashlib.sha256(data).hexdigest()}",
        }
        self.next_asset_id += 1
        self.release["assets"].append(asset)
        self.asset_bytes[asset["id"]] = data
        return copy.deepcopy(asset)

    def get_release(self, release_id: int) -> dict:
        if not self.release or self.release["id"] != release_id:
            raise stable_release.ContractError("release missing")
        return copy.deepcopy(self.release)

    def download_asset(
        self, asset_id: int, destination: pathlib.Path, byte_limit: int
    ) -> dict:
        data = self.asset_bytes[asset_id]
        if self.extra_asset == asset_id:
            data += b"unexpected extra response bytes"
        self.download_limits.append((asset_id, byte_limit))
        descriptor = os.open(
            destination,
            os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0),
            0o600,
        )
        digest = hashlib.sha256()
        written = 0
        try:
            with os.fdopen(descriptor, "wb") as output:
                for offset in range(0, len(data), 3):
                    chunk = data[offset : offset + 3]
                    allowed = byte_limit - written
                    if allowed <= 0:
                        raise stable_release.ContractError("fixture byte ceiling reached")
                    if len(chunk) > allowed:
                        output.write(chunk[:allowed])
                        digest.update(chunk[:allowed])
                        written += allowed
                        raise stable_release.ContractError("fixture byte ceiling reached")
                    output.write(chunk)
                    digest.update(chunk)
                    written += len(chunk)
                    if self.partial_asset == asset_id and written >= 2:
                        raise OSError("fixture partial transport failure")
        except Exception:
            raise
        return {"size": written, "digest": f"sha256:{digest.hexdigest()}"}

    def create_local_annotated_tag(self, tag: str, commit: str) -> str:
        if tag in self.local_tags:
            raise stable_release.ContractError("tag already exists")
        tag_object = "d" * 40
        self.local_tags[tag] = (tag_object, commit)
        return tag_object

    def push_annotated_tag(self, tag: str, tag_object: str) -> None:
        assert self.local_tags.get(tag) == (tag_object, COMMIT)
        if self.push_mode == "before-success":
            raise OSError("fixture push failed before success")
        if self.push_mode == "wrong-remote":
            self.remote_tags[tag] = ("e" * 40, "f" * 40)
            raise OSError("fixture push raced a different remote tag")
        self.remote_tags[tag] = self.local_tags[tag]
        if self.push_mode == "after-success":
            raise OSError("fixture push response was lost")

    def publish_release(self, release_id: int) -> dict:
        assert self.release and self.release["id"] == release_id
        payload = {"draft": False, "prerelease": False}
        self.patch_payloads.append(payload)
        if self.patch_mode == "before-error":
            raise OSError("fixture PATCH failed before success")
        self.release.update(payload)
        if self.patch_mode == "after-success-error":
            raise OSError("fixture PATCH response was lost")
        if self.patch_mode == "invalid-success-published":
            return {"invalid": True}
        if self.patch_mode == "invalid-success-draft":
            self.release.update({"draft": True, "prerelease": False})
            return {"invalid": True}
        if self.patch_mode == "drift":
            self.release["assets"][0]["digest"] = f"sha256:{'0' * 64}"
            raise OSError("fixture PATCH failed with release drift")
        if self.patch_mode == "tag-race":
            self.remote_tags[TAG] = ("e" * 40, "f" * 40)
        return copy.deepcopy(self.release)

    def delete_annotated_tag(self, tag: str, commit: str, tag_object: str) -> None:
        if self.remote_tags.get(tag) != (tag_object, commit):
            raise stable_release.ContractError("refusing to delete a different tag")
        del self.remote_tags[tag]
        if self.local_tags.get(tag) != (tag_object, commit):
            raise stable_release.ContractError("refusing to delete a different local tag")
        del self.local_tags[tag]

    def discard_local_tag(self, tag: str, commit: str, tag_object: str) -> None:
        if self.local_tags.get(tag) != (tag_object, commit):
            raise stable_release.ContractError("refusing to discard a different local tag")
        del self.local_tags[tag]


def fixture_assets(directory: pathlib.Path) -> None:
    files = {
        "hyperpixel2r-kms-source.tar.zst": b"source\n",
        "driver-manifest.json": json.dumps(
            {"source": {"commit": COMMIT, "tree": "b" * 40}}
        ).encode(),
        "SHA256SUMS": b"fixture checksums\n",
        "SBOM.spdx.json": b'{"spdxVersion":"SPDX-2.3"}\n',
    }
    for name, data in files.items():
        (directory / name).write_bytes(data)


def expect_rejected(label: str, function) -> None:
    try:
        function()
    except stable_release.ContractError:
        return
    raise AssertionError(f"stable release accepted hostile state: {label}")


with tempfile.TemporaryDirectory(prefix="hp2r-stable-release.") as temporary:
    root = pathlib.Path(temporary)
    assets = root / "assets"
    assets.mkdir()
    fixture_assets(assets)
    backend = FakeBackend()

    record = stable_release.create_stable_draft(backend, TAG, COMMIT, assets)
    assert backend.remote_tag(TAG) is None
    assert record["release_id"] == 42
    assert record["tag"] == TAG
    assert record["commit"] == COMMIT
    assert record["asset_fingerprint"]
    assert backend.upload_count == 4

    downloads = root / "downloads"
    verified = stable_release.verify_stable_draft(
        backend,
        TAG,
        COMMIT,
        record["release_id"],
        record["asset_fingerprint"],
        downloads,
    )
    assert sorted(path.name for path in downloads.iterdir()) == sorted(
        stable_release.REQUIRED_ASSETS
    )
    uploads_before_promotion = backend.upload_count
    stable_release.publish_verified_draft(backend, verified, downloads)
    assert backend.remote_tag(TAG) == {"object": "d" * 40, "commit": COMMIT}
    assert backend.upload_count == uploads_before_promotion
    assert backend.build_count == 0
    assert backend.patch_payloads == [{"draft": False, "prerelease": False}]
    assert backend.release and backend.release["draft"] is False
    assert backend.release["prerelease"] is False

    def staged_backend() -> tuple[FakeBackend, dict]:
        candidate = FakeBackend()
        candidate_record = stable_release.create_stable_draft(
            candidate, TAG, COMMIT, assets
        )
        return candidate, candidate_record

    candidate, candidate_record = staged_backend()
    candidate.remote_tags[TAG] = ("d" * 40, COMMIT)
    expect_rejected(
        "preexisting stable tag",
        lambda: stable_release.verify_stable_draft(
            candidate,
            TAG,
            COMMIT,
            candidate_record["release_id"],
            candidate_record["asset_fingerprint"],
            root / "tag-exists",
        ),
    )

    for label, mutation in (
        ("missing asset", lambda release: release["assets"].pop()),
        (
            "extra asset",
            lambda release: release["assets"].append(
                {
                    "id": 999,
                    "name": "foreign.bin",
                    "size": 1,
                    "digest": f"sha256:{'0' * 64}",
                }
            ),
        ),
        (
            "replaced asset identity",
            lambda release: release["assets"][0].__setitem__("id", 999),
        ),
        (
            "replaced asset digest",
            lambda release: release["assets"][0].__setitem__(
                "digest", f"sha256:{'0' * 64}"
            ),
        ),
        (
            "wrong source commit",
            lambda release: release.__setitem__("target_commitish", "c" * 40),
        ),
        ("not a draft", lambda release: release.__setitem__("draft", False)),
        ("prerelease draft", lambda release: release.__setitem__("prerelease", True)),
    ):
        candidate, candidate_record = staged_backend()
        assert candidate.release is not None
        mutation(candidate.release)
        rejected_downloads = root / label.replace(" ", "-")
        expect_rejected(
            label,
            lambda candidate=candidate, record=candidate_record: (
                stable_release.verify_stable_draft(
                    candidate,
                    TAG,
                    COMMIT,
                    record["release_id"],
                    record["asset_fingerprint"],
                    rejected_downloads,
                )
            ),
        )
        assert not rejected_downloads.exists()

    candidate, candidate_record = staged_backend()
    expect_rejected(
        "wrong accepted fingerprint",
        lambda: stable_release.verify_stable_draft(
            candidate,
            TAG,
            COMMIT,
            candidate_record["release_id"],
            "0" * 64,
            root / "wrong-fingerprint",
        ),
    )
    assert not (root / "wrong-fingerprint").exists()

    def accepted_candidate(label: str) -> tuple[FakeBackend, dict, pathlib.Path]:
        candidate = FakeBackend()
        candidate_record = stable_release.create_stable_draft(
            candidate, TAG, COMMIT, assets
        )
        candidate_downloads = root / label
        verified_record = stable_release.verify_stable_draft(
            candidate,
            TAG,
            COMMIT,
            candidate_record["release_id"],
            candidate_record["asset_fingerprint"],
            candidate_downloads,
        )
        return candidate, verified_record, candidate_downloads

    # A local tag must never substitute for the exact remote public ref.
    candidate, verified, candidate_downloads = accepted_candidate("local-mask")
    candidate.local_tags[TAG] = ("d" * 40, COMMIT)
    assert candidate.remote_tag(TAG) is None
    expect_rejected(
        "local tag collision",
        lambda: stable_release.publish_verified_draft(
            candidate, verified, candidate_downloads
        ),
    )
    assert candidate.remote_tag(TAG) is None

    # Push failure before remote success discards only the exact local tag and
    # leaves a retryable draft.
    candidate, verified, candidate_downloads = accepted_candidate("push-before")
    candidate.push_mode = "before-success"
    expect_rejected(
        "push failed before success",
        lambda: stable_release.publish_verified_draft(
            candidate, verified, candidate_downloads
        ),
    )
    assert candidate.remote_tag(TAG) is None
    assert TAG not in candidate.local_tags
    candidate.push_mode = "success"
    stable_release.publish_verified_draft(candidate, verified, candidate_downloads)
    assert candidate.remote_tag(TAG) == {"object": "d" * 40, "commit": COMMIT}

    # A lost successful push response is reconciled against the exact remote
    # annotated object and proceeds to publication.
    candidate, verified, candidate_downloads = accepted_candidate("push-after")
    candidate.push_mode = "after-success"
    stable_release.publish_verified_draft(candidate, verified, candidate_downloads)
    assert candidate.remote_tag(TAG) == {"object": "d" * 40, "commit": COMMIT}
    assert candidate.release and candidate.release["draft"] is False

    # A different remote ref is ambiguous.  Do not delete or overwrite it.
    candidate, verified, candidate_downloads = accepted_candidate("push-race")
    candidate.push_mode = "wrong-remote"
    expect_rejected(
        "push raced a different remote tag",
        lambda: stable_release.publish_verified_draft(
            candidate, verified, candidate_downloads
        ),
    )
    assert candidate.remote_tag(TAG) == {"object": "e" * 40, "commit": "f" * 40}
    assert candidate.release and candidate.release["draft"] is True

    for mode, accepted in (
        ("after-success-error", True),
        ("invalid-success-published", True),
        ("before-error", False),
        ("invalid-success-draft", False),
    ):
        candidate, verified, candidate_downloads = accepted_candidate(f"patch-{mode}")
        candidate.patch_mode = mode
        if accepted:
            stable_release.publish_verified_draft(
                candidate, verified, candidate_downloads
            )
            assert candidate.remote_tag(TAG) == {
                "object": "d" * 40,
                "commit": COMMIT,
            }
            assert candidate.release and candidate.release["draft"] is False
        else:
            expect_rejected(
                f"retryable PATCH outcome: {mode}",
                lambda candidate=candidate, verified=verified, directory=candidate_downloads: (
                    stable_release.publish_verified_draft(
                        candidate, verified, directory
                    )
                ),
            )
            assert candidate.remote_tag(TAG) is None
            assert TAG not in candidate.local_tags
            assert candidate.release and candidate.release["draft"] is True
            candidate.patch_mode = "success"
            stable_release.publish_verified_draft(
                candidate, verified, candidate_downloads
            )
            assert candidate.remote_tag(TAG) == {
                "object": "d" * 40,
                "commit": COMMIT,
            }

    for mode in ("drift", "tag-race"):
        candidate, verified, candidate_downloads = accepted_candidate(f"ambiguous-{mode}")
        candidate.patch_mode = mode
        expect_rejected(
            f"ambiguous publication state: {mode}",
            lambda candidate=candidate, verified=verified, directory=candidate_downloads: (
                stable_release.publish_verified_draft(candidate, verified, directory)
            ),
        )
        assert candidate.remote_tag(TAG) is not None

    # Downloads stream to exclusive files.  A declared-size overrun or partial
    # transport failure removes every partial and permits an exact retry.
    for mode in ("oversized", "partial"):
        candidate, candidate_record = staged_backend()
        victim = candidate.release["assets"][0]["id"]
        if mode == "oversized":
            candidate.extra_asset = victim
        else:
            candidate.partial_asset = victim
        rejected = root / f"download-{mode}"
        expect_rejected(
            f"{mode} download",
            lambda candidate=candidate, record=candidate_record, rejected=rejected: (
                stable_release.verify_stable_draft(
                    candidate,
                    TAG,
                    COMMIT,
                    record["release_id"],
                    record["asset_fingerprint"],
                    rejected,
                )
            ),
        )
        assert not rejected.exists()
        candidate.extra_asset = None
        candidate.partial_asset = None
        stable_release.verify_stable_draft(
            candidate,
            TAG,
            COMMIT,
            candidate_record["release_id"],
            candidate_record["asset_fingerprint"],
            rejected,
        )
        assert rejected.is_dir()

    # Exercise the absolute per-file and aggregate ceilings with small test
    # limits.  The response body exceeds a valid declaration at the exact cap,
    # and cleanup must still leave no partial directory.
    original_asset_limit = stable_release.MAX_ASSET_SIZE
    original_total_limit = stable_release.MAX_TOTAL_SIZE
    try:
        for mode in ("per-file-ceiling", "aggregate-ceiling"):
            candidate, candidate_record = staged_backend()
            assert candidate.release
            inventory = stable_release._asset_inventory(candidate.release)
            if mode == "per-file-ceiling":
                stable_release.MAX_ASSET_SIZE = max(
                    asset["size"] for asset in inventory
                )
                victim_asset = max(inventory, key=lambda asset: asset["size"])
            else:
                stable_release.MAX_ASSET_SIZE = original_asset_limit
                stable_release.MAX_TOTAL_SIZE = sum(
                    asset["size"] for asset in inventory
                )
                victim_asset = inventory[-1]
            candidate.extra_asset = victim_asset["id"]
            rejected = root / f"download-{mode}"
            expect_rejected(
                f"response exceeds {mode}",
                lambda candidate=candidate, record=candidate_record, rejected=rejected: (
                    stable_release.verify_stable_draft(
                        candidate,
                        TAG,
                        COMMIT,
                        record["release_id"],
                        record["asset_fingerprint"],
                        rejected,
                    )
                ),
            )
            assert not rejected.exists()
            victim_limits = [
                limit
                for asset_id, limit in candidate.download_limits
                if asset_id == victim_asset["id"]
            ]
            assert victim_limits == [victim_asset["size"]]
    finally:
        stable_release.MAX_ASSET_SIZE = original_asset_limit
        stable_release.MAX_TOTAL_SIZE = original_total_limit

print("stable release hostile simulations passed")
