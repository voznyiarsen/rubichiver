#!/usr/bin/env bash
# Weekly archive run: fetch new posts for both sites.
#
# Both sites share one SQLite archive database and one spinning disk, so they run
# sequentially. Two concurrent archivers saturate the disk and both stall
# (see AGENTS.md, "Concurrency caveat").
#
# Logging goes to the journal: journalctl --user -u rubichiver-archive.service
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
  # A failing site must not abort the other one; the exit status is reported
  # after both have run.
  #
  # --rate-limit is PER WORKER, so -j 4 at 8 allows 32 req/s between them.
  # That is far above what e621 allows (2 req/s TOTAL, answered with 503 above
  # that), and deliberately so: a measured run issued 2,856 requests in 10
  # hours, so this ceiling never binds and the run is bound by exiftool and disk
  # seeks instead. It is a safety rail, not a throttle. If the log ever shows
  # "is rate limiting this run", the run will back itself off to 1 req/s per
  # worker and then to 1 req/s in total, and will push an alert to ntfy.
  # See https://e621.net/help/api.
  ruby rubichiver.rb \
    -j 4 \
    --rate-limit 8 \
    -b "${CONFIG_DIR}/blacklist.txt" \
    -C "${CACHE_DIR}" \
    -s "${site}" \
    -c "${CONFIG_DIR}/${site}-api-credentials.txt" \
    -t "${CONFIG_DIR}/tags-${site}.txt" \
    -o "${archive}" \
    "${NOTIFY_ARGS[@]}" || return $?
  echo "=== ${site}: finished $(date -Is) ==="
}

rc=0
run_site e621 || rc=$?
run_site gelbooru || rc=$?

exit "${rc}"