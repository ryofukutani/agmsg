#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/../lib/storage.sh"
# Optional <team>: initialize that team's per-team store. Empty (the default,
# back-compatible) resolves to the shared global store.
TEAM="${1:-}"
DB="$(agmsg_team_db_path "$TEAM")"
DB_DIR="$(agmsg_team_storage_dir "$TEAM")"
mkdir -p "$DB_DIR"

# Idempotent and safe to run concurrently. When a leader fans a job out to N
# members against a fresh/override store (see #106), every send.sh races to
# initialize. Running unconditionally with IF NOT EXISTS (rather than guarding
# on the file's existence) means a process that sees the DB file but not yet
# its schema still ends up with a usable table. See #114.

# WAL is a persistent, one-time DB property and only an optimization. Changing
# the journal mode wants exclusive access, so a concurrent set on a brand-new
# DB can return "database is locked" even with a busy_timeout — set it
# best-effort; whichever initializer wins makes it stick for everyone.
agmsg_sqlite "$DB" "PRAGMA journal_mode=WAL;" >/dev/null 2>&1 || true

# Schema. IF NOT EXISTS + the busy_timeout from agmsg_sqlite make a concurrent
# first-time creation a no-op for the losers rather than an "already exists"
# abort.
agmsg_sqlite "$DB" <<'SQL'
CREATE TABLE IF NOT EXISTS messages (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  team TEXT NOT NULL,
  from_agent TEXT NOT NULL,
  to_agent TEXT NOT NULL,
  body TEXT NOT NULL,
  created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
  read_at TEXT
);

CREATE INDEX IF NOT EXISTS idx_unread ON messages(team, to_agent, read_at) WHERE read_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_history ON messages(team, created_at DESC);

-- Append-only read-state log. The message CONTENT stays in `messages` (never
-- moved); this table records ONLY read-state as append-only `message_read`
-- events (who read which message id, when). During the transition `read_at` is
-- still dual-written on `messages` for backward compatibility; once consumers
-- read read-state from here, `read_at` becomes obsolete and `messages` is
-- append-only. NOTE: content is never written here (that was the storage-axis
-- mistake that broke message delivery).
CREATE TABLE IF NOT EXISTS events (
  seq    INTEGER PRIMARY KEY AUTOINCREMENT,
  type   TEXT NOT NULL,                 -- 'message_read'
  team   TEXT NOT NULL,
  agent  TEXT NOT NULL,                 -- who read it
  msg_id INTEGER NOT NULL,              -- messages.id that was read
  at     TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))
);

CREATE INDEX IF NOT EXISTS idx_events_read ON events(type, team, agent, msg_id);

-- Per-(team,agent) read cursor: the unread boundary (highest consumed message
-- position). Unread = messages to the agent past this cursor; inbox and the
-- monitor watcher share it. Advanced on consume; the append-only events log
-- above remains the persistent per-message read record (history / external
-- tools), so this cursor is the fast operational boundary, not the audit trail.
CREATE TABLE IF NOT EXISTS cursors (
  team  TEXT NOT NULL,
  agent TEXT NOT NULL,
  pos   INTEGER NOT NULL,
  PRIMARY KEY (team, agent)
);
SQL
