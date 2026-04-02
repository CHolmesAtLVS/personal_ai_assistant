---
status: 'Planned'
created: '2026-04-02'
parent: 'feature-sidecar-sync-1.md'
pr: 26
---

# Sidecar Sync — Phase 2 Enhancements

![Status: Planned](https://img.shields.io/badge/status-Planned-blue)

Follow-up improvements to the EmptyDir + blob sidecar introduced in `feature-sidecar-sync-1.md` (PR #26). These items were deferred from the Phase 1 PR review as higher-risk or requiring design decisions.

## 1. Requirements & Constraints

- **CON-001**: Changes must not regress the EPERM fix (state must remain on EmptyDir).
- **CON-002**: ACA Consumption-only environment. MSI is not available in init containers.
- **CON-003**: ACA exec rate limit: ~5 sessions per 10 minutes. Minimize exec usage.
- **CON-004**: `az storage blob sync` internally downloads azcopy from GitHub (egress blocked from ACA). Use `az storage blob upload-batch` / `download-batch` instead.

---

## 2. Enhancements

### ENH-001 — Sentinel file: prevent destructive sync on failed restore

**Source:** PR #26 review (Copilot): sidecar SIGTERM / reconciliation runs `upload-batch` even if init restore failed and `/data` is empty, which would delete all blobs.

**Risk:** High data-loss risk. If the init container `|| echo` path is taken (restore failed, empty state), the sidecar will mirror the empty `/data` on the next sync or shutdown and delete all state in the blob container.

**Fix:**
1. Init container writes a sentinel file (`/data/.restore-ok`) after a successful restore (or creates it with an empty-state marker if starting fresh intentionally).
2. Sidecar checks for `/data/.restore-ok` before any upload. If absent, logs a warning and skips the upload.

| Task | Description | Completed | Date |
| ---- | ----------- | --------- | ---- |
| ENH-001-A | Add `touch /data/.restore-ok` at end of init container command (after chmod/chown). | | |
| ENH-001-B | Add sentinel check at start of sidecar sync loop: `[[ -f /data/.restore-ok ]] \|\| { echo 'WARN: .restore-ok absent — skipping upload'; sleep $POLL_INTERVAL; continue; }`. | | |
| ENH-001-C | Apply to SIGTERM final-sync handler as well. | | |
| ENH-001-D | Test: verify that a deliberate init failure results in no blob deletions. | | |

---

### ENH-002 — Delete detection: include directory mtimes in change check

**Source:** PR #26 review (Copilot): `find /data -newer $MARKER -type f` misses deletions (parent directory mtime changes, but no file is newer). Deletes persist in Blob until the 60-minute reconciliation.

**Fix:** Drop `-type f` from the `find` filter (or add `-type d`) so directory mtime changes from deletions trigger an immediate upload cycle.

> Note: `az storage blob upload-batch` does not delete orphaned blobs. After this change, also add an orphan-cleanup step using `az storage blob delete-batch` keyed on blobs not present in `/data`. Alternatively, keep the 60-minute reconciliation as the deletion window without adding complexity.

| Task | Description | Completed | Date |
| ---- | ----------- | --------- | ---- |
| ENH-002-A | Change `find /data -newer "$MARKER" -not -path '/data/.azure/*' -type f` to exclude `-type f` (or add `-o -type d`). | | |
| ENH-002-B | Decide: add orphan blob cleanup via `az storage blob delete-batch` or accept 60-min reconciliation as deletion window. Document decision. | | |
| ENH-002-C | Test: delete a file in `/data`, confirm sync triggers within 5 seconds. | | |

---

### ENH-003 — File permissions: preserve file mode vs directory mode in init restore

**Source:** PR #26 review (Copilot): `chmod -R 700 /data` applies executable bits to regular files unnecessarily.

**Fix:** Apply `700` to directories only and `600` to regular files:
```bash
find /data -type d -exec chmod 700 {} +
find /data -type f -exec chmod 600 {} +
```

| Task | Description | Completed | Date |
| ---- | ----------- | --------- | ---- |
| ENH-003-A | Replace `chmod -R 700 /data` in init container command with directory-only 700 + file-only 600. | | |
| ENH-003-B | Verify OpenClaw starts and writes state correctly (no permission errors on files). | | |

---

### ENH-004 — Auth: use SAS token (scoped) for init container instead of account key

**Source:** PR #26 review (Copilot): account key gives account-wide access; a container-scoped SAS with read/list only is safer for the init container.

**Current state:** Both init container and sidecar use the `STORAGE_ACCOUNT_KEY` (primary account key from Key Vault).

**Preferred end-state:**
- Init container: SAS token scoped to `openclaw-state` container, read + list only, short TTL (e.g., 24h, rotated by Terraform or a scheduled task).
- Sidecar: remains on account key (needs write) or migrates to MI when MSI-in-sidecar is confirmed.

**Constraints:**
- Terraform-managed SAS tokens have a static TTL and are stored in state. An alternative is to generate the SAS at container startup (from a KV-stored account key) and pass it to the init container via an env var set in a wrapper script.
- This is a meaningful security improvement but requires careful key management design before implementation.

| Task | Description | Completed | Date |
| ---- | ----------- | --------- | ---- |
| ENH-004-A | Design: choose between Terraform-generated SAS (static TTL in state), startup-generated SAS (from account key in KV), or accept account key for init only with read-only KV secret. Document decision. | | |
| ENH-004-B | Implement chosen approach for init container. Sidecar remains on account key until ENH-005. | | |
| ENH-004-C | Remove account-key secret ref from init container env (if no longer needed). | | |

---

### ENH-005 — Auth: migrate sidecar to Managed Identity if MSI becomes available

**Source:** PR #26 review (Copilot): sidecar uses account key; `Storage Blob Data Contributor` role assignment exists but is unused.

**Current state:** `az login --identity` in the sidecar returns HTTP 405 from the ACA MSI endpoint in Consumption-only environments. Sidecar uses `--account-key` as a workaround.

**Trigger:** If ACA updates to support MSI in sidecar containers (Consumption tier), or if the environment is migrated to a Dedicated workload profile.

| Task | Description | Completed | Date |
| ---- | ----------- | --------- | ---- |
| ENH-005-A | Monitor ACA release notes for MSI support in sidecar containers (Consumption tier). | | |
| ENH-005-B | If supported: switch sidecar from `--account-key "$STORAGE_ACCOUNT_KEY"` to `az login --identity --client-id "$MI_CLIENT_ID" --output none` + `--auth-mode login`. | | |
| ENH-005-C | Remove `STORAGE_ACCOUNT_KEY` secret ref from sidecar env block. Keep account key for init container (or remove if ENH-004 is also complete). | | |
| ENH-005-D | Confirm `mi_state_blob_contributor` role assignment is sufficient. | | |

---

### ENH-006 — Script: improve JSON capture in test-openclaw-config.sh and test-multi-model.sh

**Source:** PR #26 review (Copilot): `grep -m1 '^{'` captures only the first line starting with `{`, truncating multi-line JSON output.

**Fix:** Use `sed -n '/^{/,$p'` to capture from the first `{` to end of output, then validate with `jq -e empty`.

| Task | Description | Completed | Date |
| ---- | ----------- | --------- | ---- |
| ENH-006-A | In `scripts/test-openclaw-config.sh`: replace `grep -m1 '^{'` with `sed -n '/^{/,$p'` and validate with `jq`. | | |
| ENH-006-B | In `scripts/test-multi-model.sh`: same change for the exec-based config capture block. | | |
| ENH-006-C | Test both scripts against dev to confirm JSON is captured correctly. | | |

---

### ENH-007 — Script: decouple storage-key gating from exec-based checks in test-multi-model.sh

**Source:** PR #26 review (Copilot): the entire config validation section is skipped if `STORAGE_KEY` is unavailable, even though exec-based config reads don't require it.

**Fix:** Only gate backup-share staging steps on `STORAGE_KEY`; allow exec-based config checks to run independently.

| Task | Description | Completed | Date |
| ---- | ----------- | --------- | ---- |
| ENH-007-A | Restructure `scripts/test-multi-model.sh` to separate storage-key-dependent steps (backup share staging) from exec-based steps (config get, validate). | | |
| ENH-007-B | Test: run script without storage key available; confirm exec checks still run. | | |

---

### ENH-008 — Docs: update ARCHITECTURE.md and baseline-configuration.md

**Source:** PR #26 review (Copilot) + TASK-017 from `fix-gateway-warnings-1.md`.

**Fix:** Update architecture and baseline docs to reflect EmptyDir + Blob persistence replacing the Azure Files state share mount.

| Task | Description | Completed | Date |
| ---- | ----------- | --------- | ---- |
| ENH-008-A | `ARCHITECTURE.md`: update resource inventory (Azure Storage row) to describe Blob container as durable state + remaining backup Azure Files share. Update runtime flow section to describe init restore + sidecar sync. | | |
| ENH-008-B | `docs/baseline-configuration.md`: update "Persistent State" and "Backup" sections to describe EmptyDir + Blob architecture. Keep reference to backup share at `/mnt/openclaw-backup`. | | |
| ENH-008-C | `docs/openclaw-containerapp-operations.md`: update runbook sections that assume state is on the Azure Files mount. | | |

---

## 3. Priority Order

| Priority | Enhancement | Rationale |
| -------- | ----------- | --------- |
| 1 | ENH-001 (sentinel) | Data-loss risk — highest priority |
| 2 | ENH-003 (file perms) | Low effort, improves correctness |
| 3 | ENH-006 (JSON capture) | Low effort, improves script reliability |
| 4 | ENH-007 (script decoupling) | Low effort, improves script reliability |
| 5 | ENH-008 (docs) | Deferred from TASK-017, low risk |
| 6 | ENH-002 (delete detection) | Medium effort, design decision needed |
| 7 | ENH-004 (SAS token) | Medium effort, security design needed |
| 8 | ENH-005 (MSI sidecar) | Blocked on ACA platform update |
