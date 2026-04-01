#!/usr/bin/env bash
# backup-openclaw.sh — Run OpenClaw gateway backup and prune old archives.
#
# Runs `node /app/openclaw.mjs backup create --output <mount> --verify` inside
# the running Container App via az containerapp exec wrapped in script(1) to
# allocate a pseudo-TTY (same PTY pattern as seed-openclaw-ci.sh).
#
# Pruning is performed entirely via `az storage file` commands — no further
# exec into the container is needed for retention.
#
# Retention policy:
#   - Keep ALL archives where archive date >= today - 7 days (daily window).
#   - Keep ONE archive per ISO-week for the 10 most recent weeks (weekly window).
#   - Delete everything else.
#
# Usage:
#   bash scripts/backup-openclaw.sh [dev|prod]
#
# Prerequisites:
#   - az login with access to the environment resource group
#   - Container App is running (at least one active replica)
#   - script(1) available (util-linux; present on ubuntu-latest)
#   - /mnt/openclaw-backup mounted in the container (Terraform provisioned)
#
# Constraints:
#   - az containerapp exec is rate-limited (~5 sessions per 10 min; HTTP 429 = wait 10 min)
#   - This script uses 2 exec sessions (backup create + cp to share).
#   - Backup output path /mnt/openclaw-backup is outside /home/node/.openclaw (state mount)
#     to satisfy OpenClaw's requirement that the output path not include the source tree.
#   - SEC-001: Storage keys retrieved at runtime are ephemeral; never logged or stored.

set -euo pipefail

ENV="${1:-dev}"

case "${ENV}" in
  dev|prod) ;;
  *)
    echo "Usage: $0 [dev|prod]" >&2
    exit 1
    ;;
esac

PROJECT="${TF_VAR_project:-${TF_VAR_PROJECT:-paa}}"
APP_NAME="${PROJECT}-${ENV}-app"
RG_NAME="${PROJECT}-${ENV}-rg"
# Derive storage account name using the same sanitization/truncation as Terraform:
# substr(replace("${project}${environment}ocstate", "-", ""), 0, 24)
RAW_STORAGE_ACCOUNT="${PROJECT}${ENV}ocstate"
STORAGE_ACCOUNT="${RAW_STORAGE_ACCOUNT//-/}"
STORAGE_ACCOUNT="${STORAGE_ACCOUNT:0:24}"
BACKUP_SHARE="openclaw-backup"
BACKUP_MOUNT="/mnt/openclaw-backup"

echo "BACKUP: environment=${ENV}  app=${APP_NAME}  rg=${RG_NAME}"
echo "BACKUP: share=${BACKUP_SHARE}  mount=${BACKUP_MOUNT}"

# ── PTY wrapper ──────────────────────────────────────────────────────────────────
# Wraps az containerapp exec in script(1) so it gets a pseudo-TTY.
# az containerapp exec calls termios.tcgetattr() during WebSocket setup;
# CI runners have no TTY, causing ENOTTY. script(1) (util-linux) allocates
# a pty via openpty(), satisfying tcgetattr(). tr -d '\r' strips pty CR bytes.
pty_exec() {
  local oc_cmd="$1"
  script -q -c "az containerapp exec \
    --name ${APP_NAME} \
    --resource-group ${RG_NAME} \
    --command '${oc_cmd}'" /dev/null \
    | tr -d '\r'
}

# ── Step 1: Get storage key ───────────────────────────────────────────────────────
echo "BACKUP: fetching storage key..."
STORAGE_KEY=$(az storage account keys list \
  --account-name "${STORAGE_ACCOUNT}" \
  --resource-group "${RG_NAME}" \
  --query "[0].value" -o tsv 2>/dev/null)
if [[ -z "${STORAGE_KEY}" ]]; then
  echo "ERROR: could not retrieve storage key for ${STORAGE_ACCOUNT}" >&2
  exit 1
fi
echo "BACKUP: storage key retrieved"

# ── Step 2: Run backup via PTY exec ──────────────────────────────────────────────
# Two-exec strategy (mirrors seed-openclaw-ci.sh pattern):
#
#   Exec 1/2 — backup create to /tmp:
#     OpenClaw writes the archive to /tmp (local tmpfs), NOT directly to
#     /mnt/openclaw-backup (Azure Files SMB). This avoids EPERM from
#     copy_file_range on CIFS: Node.js fs.copyFile() uses copy_file_range;
#     Azure Files SMB returns EPERM for it; libuv does NOT fall back on EPERM
#     (only ENOTSUP/ENOSYS/EXDEV). All output is captured for archive name
#     extraction. This exec must be a single command — && chains in exec
#     suppress all output past the first command.
#
#   Exec 2/2 — cp to backup share:
#     After --verify succeeds on /tmp, GNU cp transfers the archive to the
#     Azure Files share. cp falls back gracefully from copy_file_range EPERM
#     to read+write. Runs only if exec 1 succeeded.
#
# Exec budget: 2 sessions per backup run. Combined with seed script (2), peak = 4/5.
BACKUP_STAGING="/tmp"

echo "BACKUP: running backup create --verify (exec 1/2)..."
BACKUP_OUTPUT=$(pty_exec "node /app/openclaw.mjs backup create --output ${BACKUP_STAGING} --verify" 2>&1) || true

# Print output for CI log visibility regardless of outcome
echo "${BACKUP_OUTPUT}"

# Exit code from pty_exec (script|tr pipeline) is always from tr — unreliable.
# Detect failure via output pattern matching only.
if echo "${BACKUP_OUTPUT}" | grep -qi "ENOTTY"; then
  echo "ERROR: ENOTTY — exec did not get a PTY; check script(1) availability" >&2
  exit 1
fi

if echo "${BACKUP_OUTPUT}" | grep -qi "429\|rate.limit\|too many requests"; then
  echo "ERROR: HTTP 429 — az containerapp exec rate-limited; wait 10 minutes and retry" >&2
  exit 1
fi

if echo "${BACKUP_OUTPUT}" | grep -qi "ClusterExecFailure\|ClusterExecEndpoint"; then
  echo "ERROR: az containerapp exec returned a cluster error" >&2
  exit 1
fi

if ! echo "${BACKUP_OUTPUT}" | grep -qi "Archive verification: passed"; then
  echo "ERROR: backup --verify did not pass or backup did not complete" >&2
  exit 1
fi

# Extract archive filename from output (e.g. 2026-03-09T00-00-00.000Z-openclaw-backup.tar.gz)
ARCHIVE_NAME=$(echo "${BACKUP_OUTPUT}" | grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9T\.\-]+Z-openclaw-backup\.tar\.gz' | head -1 || true)
if [[ -z "${ARCHIVE_NAME}" ]]; then
  echo "WARNING: could not extract archive filename from backup output; listing output below"
  echo "${BACKUP_OUTPUT}"
else
  echo "BACKUP: archive created: ${ARCHIVE_NAME}"
fi

# ── Step 2b: Copy verified archive to backup share (exec 2/2) ────────────────────
# Uses exact archive filename (not a glob) because az containerapp exec --command
# does not invoke a shell — wildcards are passed literally to the program.
# Exit code detection via COPY_EXIT is unreliable: script(1) | tr pipeline always
# exits 0 (tr's exit code). Use output pattern matching instead.
echo "BACKUP: copying archive to backup share (exec 2/2)..."
COPY_OUTPUT=$(pty_exec "cp /tmp/${ARCHIVE_NAME} ${BACKUP_MOUNT}/" 2>&1) || true
echo "${COPY_OUTPUT}"
if echo "${COPY_OUTPUT}" | grep -qi "cannot stat\|no such file\|cp:.*error\|ClusterExecFailure"; then
  echo "ERROR: cp of archive to backup share failed" >&2
  exit 1
fi
echo "BACKUP: archive copied to ${BACKUP_MOUNT}"


prune_archives() {
  local today_epoch
  today_epoch=$(date -u +%s)
  local daily_cutoff_epoch=$(( today_epoch - 7 * 86400 ))
  local weekly_cutoff_epoch=$(( today_epoch - 70 * 86400 ))

  echo "BACKUP: listing archives for pruning..."
  local file_list
  file_list=$(az storage file list \
    --account-name "${STORAGE_ACCOUNT}" \
    --account-key "${STORAGE_KEY}" \
    --share-name "${BACKUP_SHARE}" \
    --query "[?ends_with(name, '.tar.gz')].name" \
    -o tsv 2>/dev/null || true)

  if [[ -z "${file_list}" ]]; then
    echo "BACKUP: no archives found in share; nothing to prune"
    return 0
  fi

  local kept=0
  local deleted=0
  # Track which ISO weeks we have already kept an archive for (weekly window)
  declare -A seen_iso_weeks

  # Sort files to process oldest first — ensures we keep the oldest archive per week
  local sorted_files
  sorted_files=$(echo "${file_list}" | sort)

  while IFS= read -r filename; do
    [[ -z "${filename}" ]] && continue

    # Parse the leading YYYY-MM-DD prefix from the filename
    local file_date
    file_date=$(echo "${filename}" | grep -oE '^[0-9]{4}-[0-9]{2}-[0-9]{2}' || true)
    if [[ -z "${file_date}" ]]; then
      echo "BACKUP: WARNING: cannot parse date from '${filename}' — skipping (safe-fail)"
      (( kept++ )) || true
      continue
    fi

    local file_epoch
    file_epoch=$(date -u -d "${file_date}" +%s 2>/dev/null || true)
    if [[ -z "${file_epoch}" ]]; then
      echo "BACKUP: WARNING: cannot parse epoch for '${filename}' — skipping (safe-fail)"
      (( kept++ )) || true
      continue
    fi

    # Daily window: keep unconditionally
    if (( file_epoch >= daily_cutoff_epoch )); then
      echo "BACKUP: keep (daily)   ${filename}"
      (( kept++ )) || true
      continue
    fi

    # Weekly window: keep one per ISO-week (oldest first = first seen per week)
    if (( file_epoch >= weekly_cutoff_epoch )); then
      local iso_week
      iso_week=$(date -u -d "${file_date}" +%G-W%V 2>/dev/null || true)
      if [[ -n "${iso_week}" && -z "${seen_iso_weeks[${iso_week}]:-}" ]]; then
        seen_iso_weeks["${iso_week}"]="${filename}"
        echo "BACKUP: keep (weekly)  ${filename}  [${iso_week}]"
        (( kept++ )) || true
        continue
      fi
    fi

    # Delete
    echo "BACKUP: delete         ${filename}"
    az storage file delete \
      --account-name "${STORAGE_ACCOUNT}" \
      --account-key "${STORAGE_KEY}" \
      --share-name "${BACKUP_SHARE}" \
      --path "${filename}" \
      --output none 2>&1 || echo "BACKUP: WARNING: failed to delete ${filename} (continuing)"
    (( deleted++ )) || true

  done <<< "${sorted_files}"

  echo "BACKUP: pruning complete — kept=${kept}  deleted=${deleted}"
  KEPT=${kept}
  DELETED=${deleted}
}

KEPT=0
DELETED=0
prune_archives || echo "BACKUP: WARNING: pruning encountered errors (non-fatal)"

# ── Summary ───────────────────────────────────────────────────────────────────────
echo "BACKUP: ✅ backup=${ARCHIVE_NAME:-unknown}  kept=${KEPT}  deleted=${DELETED}"
