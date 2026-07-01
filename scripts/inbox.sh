#!/usr/bin/env bash
set -euo pipefail

# Usage: inbox.sh <team> <agent_id> [--quiet]
# Shows unread messages and marks them as read.
# --quiet: only output if there are unread messages (for hooks)

TEAM="${1:?Usage: inbox.sh <team> <agent_id> [--quiet]}"
AGENT="${2:?Missing agent_id}"
QUIET=false
if [ "${3:-}" = "--quiet" ]; then
  QUIET=true
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib/storage.sh"
# Read + mark through the team's storage backend (sqlite default).
agmsg_storage_load "$TEAM"

if ! storage_exists "$TEAM"; then
  if [ "$QUIET" = true ]; then exit 0; fi
  echo "No messages (DB not initialized)"
  exit 0
fi

# Unread = messages past the read cursor (the same cursor the monitor watcher
# uses). Records are <pos> <US> <ts> <US> <team> <US> <from> <US> <to> <US> <body>.
CUR=$(storage_get_cursor "$TEAM" "$AGENT")
UNREAD=$(storage_watch_after "$TEAM" "$AGENT" "$CUR")

if [ -z "$UNREAD" ]; then
  if [ "$QUIET" = true ]; then exit 0; fi
  echo "No new messages."
  exit 0
fi

# Display, tracking the last delivered position.
COUNT=$(echo "$UNREAD" | wc -l | tr -d ' ')
echo "$COUNT new message(s):"
echo ""
LASTPOS="$CUR"
while IFS=$'\x1f' read -r pos ts _team from to body; do
  [ -z "$pos" ] && continue
  echo "  [$ts] $from: $body"
  LASTPOS="$pos"
done <<< "$UNREAD"
echo ""

# Advance the read cursor (the unread boundary) and write the persistent read
# record (append-only message_read events + read_at) for back-compat / history.
# Non-fatal — may fail in sandboxed environments.
storage_set_cursor "$TEAM" "$AGENT" "$LASTPOS"
storage_mark_read "$TEAM" "$AGENT"
