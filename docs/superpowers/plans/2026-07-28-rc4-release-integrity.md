# RC4 Release Integrity Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Bind a manually dispatched release to the checked-out source commit and install the release validators only from a complete, hash-locked dependency graph before publishing RC4.

**Architecture:** The release workflow will separately prove the workflow-dispatch commit contains `release.yml`, then derive the release commit solely from checked-out `HEAD`.  Packaging, manifest assertion, tag creation, and release target all flow from that one output.  Validator dependencies are declared in a small direct input, compiled into a complete multi-platform SHA-256 lock, and installed in an isolated, lock-digest-keyed virtual environment.

**Tech Stack:** GitHub Actions, Bash, Python `venv` and pip hash-checking mode, `pip-tools`, Draft 2020-12 `check-jsonschema`, SPDX Tools Python, mise, Docker/actionlint.

## Global Constraints

- Preserve immutable RC1 through RC3 tags, releases, and assets.
- Use the checked-out source `HEAD`, never `GITHUB_SHA`, as the release source identity.
- Keep `GITHUB_SHA` limited to proving the dispatch ref contains the workflow definition required by GitHub.
- Require hashes for every locked validator artifact and install with `--require-hashes --no-deps --isolated`.
- Cache validators only under a key derived from the complete lock digest.
- Add failing executable contract tests before production changes.
- Land a focused GitButler commit with exactly one Codex co-author trailer.
- Do not touch the Raspberry Pi or maintainer environment values.

---

### Task 1: Prove checked-out source binding

**Files:**
- Modify: `tests/release-contract.sh`
- Modify: `.github/workflows/release.yml`

**Interfaces:**
- Consumes: `workflow_dispatch.inputs.source_ref`, `github.sha`, checkout `HEAD`
- Produces: `steps.preflight.outputs.commit`, the sole commit passed to packaging and tag creation

- [ ] **Step 1: Write the failing workflow contract and local fixture**

Require the workflow to prove its dispatch ref contains `.github/workflows/release.yml`, derive `source_commit` with `git rev-parse 'HEAD^{commit}'`, reject source binding through `GITHUB_SHA`, and assert the tag/manifest target a source branch whose commit differs from the dispatch ref.

- [ ] **Step 2: Run the focused contract to verify RED**

Run: `bash tests/release-contract.sh`

Expected: FAIL because the workflow derives `source_commit` from `GITHUB_SHA` and has no dispatch-workflow existence proof.

- [ ] **Step 3: Make the workflow use the checked-out commit**

Add a dispatch-definition proof using `github.sha`, derive `source_commit` from `HEAD`, assert the generated manifest source commit equals `RELEASE_COMMIT`, and retain the exact remote race check/tag push and post-push dereference comparison.

- [ ] **Step 4: Run the focused contract to verify GREEN**

Run: `bash tests/release-contract.sh`

Expected: PASS; the local simulation packages and tags the checked-out source commit even when it differs from the dispatch-workflow commit.

### Task 2: Create a complete hash-locked validator supply chain

**Files:**
- Create: `release/validator-requirements.in`
- Create: `release/validator-lock-tools.txt`
- Create: `scripts/lock-release-validators.sh`
- Modify: `release/validator-requirements.txt`
- Modify: `scripts/validate-release-metadata.sh`
- Modify: `tests/release-contract.sh`
- Modify: `docs/provenance.md`

**Interfaces:**
- Consumes: direct validator pins `spdx-tools==0.8.3` and `check-jsonschema==0.37.4`
- Produces: a transitive requirements lock whose every package has one or more SHA-256 hashes, plus an isolated validator venv keyed by the lock digest

- [ ] **Step 1: Write failing hash-lock and tamper tests**

Require every pinned requirement in the lock to have SHA-256 hashes, require the installer flags `--isolated --require-hashes --no-deps`, and copy/tamper the lock in a local validator fixture to prove installation fails closed.

- [ ] **Step 2: Run the focused contract to verify RED**

Run: `bash tests/release-contract.sh`

Expected: FAIL because the current lock has no hashes and pip uses neither `--require-hashes` nor `--isolated --no-deps`.

- [ ] **Step 3: Generate the complete lock and isolated installer**

Use a hash-pinned `pip-tools` bootstrap in `scripts/lock-release-validators.sh`; compile `validator-requirements.in` with `--generate-hashes`.  Rebuild the validator venv only when the complete lock digest changes and install with exactly `pip install --isolated --require-hashes --no-deps --requirement`.

- [ ] **Step 4: Run the focused contract to verify GREEN on macOS**

Run: `bash tests/release-contract.sh`

Expected: PASS, including a real validator run and a deliberately corrupted-hash installation rejection.

### Task 3: Publish and verify RC4

**Files:**
- Modify: `release/current-release.txt`
- Modify: `README.md`
- Modify: `.superpowers/sdd/2026-07-27-rpi-plane-radar-product-readiness/task-7-report.md` in the Plane Radar planning repository

**Interfaces:**
- Consumes: `v0.1.0-rc.4`, the hardened public `main` workflow, downloaded GitHub release assets
- Produces: a public prerelease whose tag dereferences to the checked-out custom `source_ref` commit

- [ ] **Step 1: Update canonical public status**

Set `release/current-release.txt` and every README release command/status marker to `v0.1.0-rc.4`.

- [ ] **Step 2: Run full local and clean-clone verification**

Run: `mise run verify`, actionlint, shell/JSON/diff/security scans, and two deterministic packages from a fresh public clone.

Expected: all pass with the real hash-locked validator on macOS; CI will provide the clean Linux proof.

- [ ] **Step 3: Commit and land with GitButler**

Create a focused change with one trailer:

```text
Co-authored-by: Codex <noreply@openai.com>
```

- [ ] **Step 4: Dispatch with distinct workflow and source refs**

Create a durable source branch/ref at the new commit, advance `main` with a harmless workflow-ref-only commit if needed, then dispatch the workflow definition from `main` while passing the distinct source ref.  Confirm the tag does not exist before verification completes.

- [ ] **Step 5: Verify published RC4 independently**

Download every asset; validate checksums, Draft 2020-12 metadata, SPDX 2.3, dual file checksums, archive safety, exact annotated-tag dereference, prerelease state, and workflow-signer attestations.  Update the Task 7 report opening outcome to RC4 while preserving RC1-RC3 history.
