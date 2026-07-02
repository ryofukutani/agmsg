#!/usr/bin/env bash
set -euo pipefail

# Usage: inbox.sh <team> <agent_id> [--quiet]
# Shows unread messages and marks the displayed message ids as read.
# --quiet: only output if there are unread messages (for hooks)

TEAM="${1:?Usage: inbox.sh <team> <agent_id> [--quiet]}"
AGENT="${2:?Missing agent_id}"
QUIET=false
if [ "${3:-}" = "--quiet" ]; then
  QUIET=true
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
IDS_FILE="$(mktemp "${TMPDIR:-/tmp}/agmsg-inbox-ids.XXXXXX")"
trap 'rm -f "$IDS_FILE"' EXIT

if [ "$QUIET" = true ]; then
  "$SCRIPT_DIR/inbox-peek.sh" "$TEAM" "$AGENT" --quiet --ids-file "$IDS_FILE"
else
  "$SCRIPT_DIR/inbox-peek.sh" "$TEAM" "$AGENT" --ids-file "$IDS_FILE"
fi

"$SCRIPT_DIR/mark-read.sh" "$TEAM" "$AGENT" --ids-file "$IDS_FILE"
