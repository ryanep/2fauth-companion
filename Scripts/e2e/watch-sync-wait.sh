#!/bin/sh
set -eu

if [ -z "${WATCH_SYNC_MARKER_PATH:-}" ]; then
  printf '%s\n' 'WATCH_SYNC_MARKER_PATH is required' >&2
  exit 1
fi

timeout_seconds="${WATCH_SYNC_TIMEOUT_SECONDS:-20}"
deadline=$(( $(date +%s) + timeout_seconds ))

while [ "$(date +%s)" -lt "$deadline" ]; do
  if [ -f "$WATCH_SYNC_MARKER_PATH" ]; then
    marker_json="$(tr -d '\n' < "$WATCH_SYNC_MARKER_PATH")"
    event="$(printf '%s' "$marker_json" | ruby -rjson -e 'data = JSON.parse(STDIN.read); print(data.fetch("event", ""))')"
    case "$event" in
      watch.sync_updated_context)
        exit 0
        ;;
      watch.sync_skipped_not_activated|watch.sync_skipped_not_paired|watch.sync_skipped_watch_app_not_installed|watch.sync_encode_failed|watch.sync_update_context_failed)
        printf '%s\n' "Watch sync failed: $marker_json" >&2
        exit 1
        ;;
    esac
  fi
  sleep 1
done

printf '%s\n' "Timed out waiting for watch sync marker at $WATCH_SYNC_MARKER_PATH" >&2
exit 1
