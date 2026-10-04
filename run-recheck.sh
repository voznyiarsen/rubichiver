#!/usr/bin/env bash
# Monthly metadata refresh for already-archived posts (no downloads).
#
# e621 batches 300 ids per request. Gelbooru has no bulk id lookup, so its line
# costs one API request per archived post — expect it to take a long time on a
# large archive.
#
# Logging goes to the journal: journalctl --user -u rubichiver-recheck.service
set -euo pipefail

RUBICHIVER_DIR="/home/tsuchinoko/rubichiver"
CONFIG_DIR="${RUBICHIVER_DIR}/config"
CACHE_DIR="${RUBICHIVER_DIR}/cache"

# Set by the systemd unit. Unset means no alerts, which is the right default for
# a manual run.
NOTIFY_ARGS=()
if [ -n "${RUBICHIVER_NOTIFY_URL:-}" ]; then
  NOTIFY_ARGS=(--notify "${RUBICHIVER_NOTIFY_URL}")
fi

cd "${RUBICHIVER_DIR}"

run_site() {
  local site="$1"
  local archive="/mnt/hdd/${site}-archive"

  echo "=== ${site}: starting $(date -Is) ==="
  ruby rubichiver.rb \
    -j 4 \
    --rate-limit 8 \
    -b "${CONFIG_DIR}/blacklist.txt" \
    -C "${CACHE_DIR}" \
    -s "${site}" \
    -c "${CONFIG_DIR}/${site}-api-credentials.txt" \
    -t "${CONFIG_DIR}/tags-${site}.txt" \
    -o "${archive}" \
    --recache-post-tags \
    "${NOTIFY_ARGS[@]}" || return $?
  echo "=== ${site}: finished $(date -Is) ==="
}

rc=0
run_site e621 || rc=$?
run_site gelbooru || rc=$?

exit "${rc}"