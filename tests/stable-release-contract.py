#!/usr/bin/env python3
"""Hostile, stateful simulations of stable draft creation and promotion."""

from __future__ import annotations

import copy
import hashlib
import importlib.util
import json
import pathlib
import tempfile


ROOT = pathlib.Path(__file__).resolve().parents[1]
MODULE_PATH = ROOT / "scripts" / "stable_release.py"
SPEC = importlib.util.spec_from_file_location("stable_release", MODULE_PATH)
if SPEC is None or SPEC.loader is None:
    raise SystemExit("cannot load scripts/stable_release.py")
stable_release = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(stable_release)

TAG = "v0.1.0"
COMMIT = "a" * 40


class FakeBackend:
    def __init__(self) -> None:
        self.release: dict | None = None
        self.asset_bytes: dict[int, bytes] = {}
        self.tags: dict[str, str] = {}
        self.upload_count = 0
        self.build_count = 0
        self.patch_payloads: list[dict] = []
        self.next_asset_id = 100

    def tag_commit(self, tag: str) -> str | None:
        return self.tags.get(tag)

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

    def upload_asset(self, release_id: int, name: str, data: bytes) -> dict:
        assert self.release and self.release["id"] == release_id
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

    def download_asset(self, asset_id: int) -> bytes:
        return self.asset_bytes[asset_id]

    def create_annotated_tag(self, tag: str, commit: str) -> None:
        if tag in self.tags:
            raise stable_release.ContractError("tag already exists")
        self.tags[tag] = commit

    def publish_release(self, release_id: int) -> dict:
        assert self.release and self.release["id"] == release_id
        payload = {"draft": False, "prerelease": False}
        self.patch_payloads.append(payload)
        self.release.update(payload)
        return copy.deepcopy(self.release)

    def delete_annotated_tag(self, tag: str, commit: str) -> None:
        if self.tags.get(tag) != commit:
            raise stable_release.ContractError("refusing to delete a different tag")
        del self.tags[tag]


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
    assert backend.tag_commit(TAG) is None
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
    assert backend.tag_commit(TAG) == COMMIT
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
    candidate.tags[TAG] = COMMIT
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

    class PatchFails(FakeBackend):
        def __init__(self, after_success: bool) -> None:
            super().__init__()
            self.after_success = after_success
            self.fail_patch = True

        def publish_release(self, release_id: int) -> dict:
            if not self.fail_patch:
                return super().publish_release(release_id)
            if self.after_success:
                super().publish_release(release_id)
            raise OSError("fixture PATCH transport failure")

    for after_success in (True, False):
        candidate = PatchFails(after_success)
        candidate_record = stable_release.create_stable_draft(
            candidate, TAG, COMMIT, assets
        )
        candidate_downloads = root / f"patch-{after_success}"
        verified = stable_release.verify_stable_draft(
            candidate,
            TAG,
            COMMIT,
            candidate_record["release_id"],
            candidate_record["asset_fingerprint"],
            candidate_downloads,
        )
        if after_success:
            published = stable_release.publish_verified_draft(
                candidate, verified, candidate_downloads
            )
            assert published["asset_fingerprint"] == candidate_record["asset_fingerprint"]
            assert candidate.tag_commit(TAG) == COMMIT
            assert candidate.release and candidate.release["draft"] is False
        else:
            expect_rejected(
                "definite publish PATCH failure",
                lambda: stable_release.publish_verified_draft(
                    candidate, verified, candidate_downloads
                ),
            )
            assert candidate.tag_commit(TAG) is None
            assert candidate.release and candidate.release["draft"] is True
            candidate.fail_patch = False
            stable_release.publish_verified_draft(candidate, verified, candidate_downloads)
            assert candidate.tag_commit(TAG) == COMMIT

    class AmbiguousPatchFailure(PatchFails):
        def publish_release(self, release_id: int) -> dict:
            assert self.release
            self.release["assets"][0]["digest"] = f"sha256:{'0' * 64}"
            raise OSError("fixture PATCH failure with concurrent drift")

    candidate = AmbiguousPatchFailure(False)
    candidate_record = stable_release.create_stable_draft(candidate, TAG, COMMIT, assets)
    candidate_downloads = root / "patch-ambiguous"
    verified = stable_release.verify_stable_draft(
        candidate,
        TAG,
        COMMIT,
        candidate_record["release_id"],
        candidate_record["asset_fingerprint"],
        candidate_downloads,
    )
    expect_rejected(
        "ambiguous PATCH failure",
        lambda: stable_release.publish_verified_draft(
            candidate, verified, candidate_downloads
        ),
    )
    assert candidate.tag_commit(TAG) == COMMIT

print("stable release hostile simulations passed")
