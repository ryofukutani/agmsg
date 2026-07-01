#!/usr/bin/env bash
# sqlite storage driver — the default backend.
#
# Wraps the message store in the storage_* contract so message call sites can be
# backend-agnostic. SCHEMA IS UNCHANGED from the non-driver path: message
# CONTENT lives in the `messages` table; read-state is the append-only `events`
# log (dual-written with messages.read_at during the transition). This driver
# is a faithful wrap of the existing SQL — same records, same ordering.
#
# Sourced by agmsg_storage_load(); assumes lib/storage.sh helpers (agmsg_sqlite,
# agmsg_team_db_path, agmsg_sqlesc, agmsg_skill_dir) are already in scope. Each
# function takes the <team> and resolves that team's store, so a per-team
# backend and the shared global store are handled identically.

# storage_exists <team> — has this team's store been initialized?
storage_exists() { [ -f "$(agmsg_team_db_path "$1")" ]; }

# storage_send <team> <from> <to> <body>
storage_send() {
  local team="$1" from="$2" to="$3" body="$4" db init insert
  db="$(agmsg_team_db_path "$team")"
  init="$(agmsg_skill_dir)/scripts/internal/init-db.sh"
  [ -f "$db" ] || bash "$init" "$team" >/dev/null
  insert="INSERT INTO messages (team, from_agent, to_agent, body) VALUES ('$(agmsg_sqlesc "$team")', '$(agmsg_sqlesc "$from")', '$(agmsg_sqlesc "$to")', '$(agmsg_sqlesc "$body")');"
  # Retry once after ensuring the schema (the #114 concurrent first-write race).
  # Pipe via stdin so a large body cannot overflow the OS command-line limit.
  if ! printf '%s\n' "$insert" | agmsg_sqlite "$db" 2>/dev/null; then
    bash "$init" "$team" >/dev/null
    printf '%s\n' "$insert" | agmsg_sqlite "$db"
  fi
}

# storage_list_unread <team> <agent>
# Emits one record per unread message: from <US> body <US> created_at  (oldest first).
storage_list_unread() {
  local team="$1" agent="$2" db tl al
  db="$(agmsg_team_db_path "$team")"
  [ -f "$db" ] || return 0
  tl="$(agmsg_sqlesc "$team")"; al="$(agmsg_sqlesc "$agent")"
  agmsg_sqlite "$db" "
    SELECT from_agent || char(31) || replace(replace(body, char(10), '\n'), char(9), '\t') || char(31) || created_at
    FROM messages WHERE team='$tl' AND to_agent='$al' AND read_at IS NULL
    ORDER BY created_at ASC;
  "
}

# storage_mark_read <team> <agent>
# Dual-write: append message_read events (append-only read-state) for the unread
# set, AND set read_at for back-compat. The events INSERT runs before the UPDATE
# so read_at IS NULL still selects the just-read set.
storage_mark_read() {
  local team="$1" agent="$2" db tl al
  db="$(agmsg_team_db_path "$team")"
  [ -f "$db" ] || return 0
  tl="$(agmsg_sqlesc "$team")"; al="$(agmsg_sqlesc "$agent")"
  agmsg_sqlite "$db" "
INSERT INTO events (type, team, agent, msg_id)
  SELECT 'message_read', team, to_agent, id FROM messages
  WHERE team='$tl' AND to_agent='$al' AND read_at IS NULL;
UPDATE messages SET read_at=strftime('%Y-%m-%dT%H:%M:%SZ','now')
  WHERE team='$tl' AND to_agent='$al' AND read_at IS NULL;
" 2>/dev/null || true
}

# Current sqlite schema/data version. Bump when adding a migration step below.
_SQLITE_SCHEMA_VERSION=1

# storage_ensure_schema <team> — bring an existing store up to the current schema
# version, applying pending DATA migrations. Gated by PRAGMA user_version so it
# runs once and never double-applies; called lazily on store load. A fresh store
# runs the (no-op-on-empty) migrations and lands at the current version.
storage_ensure_schema() {
  local team="$1" db v
  db="$(agmsg_team_db_path "$team")"
  [ -f "$db" ] || return 0
  v="$(agmsg_sqlite "$db" "PRAGMA user_version;" 2>/dev/null || echo 0)"
  case "$v" in ''|*[!0-9]*) v=0 ;; esac
  [ "$v" -ge "$_SQLITE_SCHEMA_VERSION" ] && return 0

  # A pre-migration store may predate the events/cursors tables — ensure the
  # current schema exists (idempotent) before migrating data into it.
  bash "$(agmsg_skill_dir)/scripts/internal/init-db.sh" "$team" >/dev/null 2>&1 || true

  # --- migration #1: seed the read cursor from the existing read_at boundary ---
  # Without this, the cursor model (unread = past cursor) would treat all
  # already-read history (read_at set, cursor still 0) as unread and re-deliver
  # it on the first new-version run. cursor(agent) = highest id it has read.
  if [ "$v" -lt 1 ]; then
    agmsg_sqlite "$db" "
      INSERT INTO cursors (team, agent, pos)
        SELECT team, to_agent, MAX(id) FROM messages
        WHERE read_at IS NOT NULL GROUP BY team, to_agent
      ON CONFLICT(team,agent) DO UPDATE SET pos=excluded.pos WHERE excluded.pos > cursors.pos;
    " 2>/dev/null || true
  fi

  agmsg_sqlite "$db" "PRAGMA user_version=$_SQLITE_SCHEMA_VERSION;" 2>/dev/null || true
}

# storage_consume <team> <agent> <pos> — mark everything up to <pos> consumed:
# advance the read cursor (forward only) AND write the persistent read record
# (append-only message_read events + read_at) for messages up to <pos>. Bounded
# by <pos> (not a bulk "mark all unread") so the watcher never records past a
# message it has not actually delivered (#67).
storage_consume() {
  local team="$1" agent="$2" pos="$3" db tl al
  db="$(agmsg_team_db_path "$team")"
  [ -f "$db" ] || return 0
  case "$pos" in ''|*[!0-9]*) return 0 ;; esac
  tl="$(agmsg_sqlesc "$team")"; al="$(agmsg_sqlesc "$agent")"
  agmsg_sqlite "$db" "
    INSERT INTO events (type, team, agent, msg_id)
      SELECT 'message_read', team, to_agent, id FROM messages
      WHERE team='$tl' AND to_agent='$al' AND id<=$pos AND read_at IS NULL;
    UPDATE messages SET read_at=strftime('%Y-%m-%dT%H:%M:%SZ','now')
      WHERE team='$tl' AND to_agent='$al' AND id<=$pos AND read_at IS NULL;
    INSERT INTO cursors (team, agent, pos) VALUES ('$tl', '$al', $pos)
      ON CONFLICT(team,agent) DO UPDATE SET pos=excluded.pos WHERE excluded.pos > cursors.pos;
  " 2>/dev/null || true
}

# storage_get_cursor <team> <agent> — the read cursor (unread boundary), 0 if none.
storage_get_cursor() {
  local team="$1" agent="$2" db tl al
  db="$(agmsg_team_db_path "$team")"
  [ -f "$db" ] || { echo 0; return 0; }
  tl="$(agmsg_sqlesc "$team")"; al="$(agmsg_sqlesc "$agent")"
  agmsg_sqlite "$db" "SELECT COALESCE((SELECT pos FROM cursors WHERE team='$tl' AND agent='$al'), 0);" 2>/dev/null || echo 0
}

# storage_set_cursor <team> <agent> <pos> — persist the read cursor.
storage_set_cursor() {
  local team="$1" agent="$2" pos="$3" db init tl al
  db="$(agmsg_team_db_path "$team")"
  init="$(agmsg_skill_dir)/scripts/internal/init-db.sh"
  [ -f "$db" ] || bash "$init" "$team" >/dev/null
  case "$pos" in ''|*[!0-9]*) pos=0 ;; esac
  tl="$(agmsg_sqlesc "$team")"; al="$(agmsg_sqlesc "$agent")"
  agmsg_sqlite "$db" "
    INSERT INTO cursors (team, agent, pos) VALUES ('$tl', '$al', $pos)
    ON CONFLICT(team, agent) DO UPDATE SET pos=excluded.pos;
  " 2>/dev/null || true
}

# storage_watch_tip <team> — current high-water cursor for the team's store
# (the newest message id). A fresh watcher starts here so it streams only what
# arrives next (no replay of history).
storage_watch_tip() {
  local team="$1" db tl
  db="$(agmsg_team_db_path "$team")"
  [ -f "$db" ] || { echo 0; return 0; }
  tl="$(agmsg_sqlesc "$team")"
  agmsg_sqlite "$db" "SELECT COALESCE(MAX(id),0) FROM messages WHERE team='$tl';" 2>/dev/null || echo 0
}

# storage_watch_after <team> <agent> <cursor>
# Emit new messages to <agent> with position > <cursor>, oldest first, as:
#   <pos> <US> <ts> <US> <team> <US> <from> <US> <to> <US> <body>
# <pos> is the cursor type (the message id); body CR stripped + newlines -> "\n".
storage_watch_after() {
  local team="$1" agent="$2" cursor="$3" db tl al
  db="$(agmsg_team_db_path "$team")"
  [ -f "$db" ] || return 0
  case "$cursor" in ''|*[!0-9]*) cursor=0 ;; esac
  tl="$(agmsg_sqlesc "$team")"; al="$(agmsg_sqlesc "$agent")"
  agmsg_sqlite -separator "$(printf '\037')" "$db" "
    SELECT id, created_at, team, from_agent, to_agent,
           replace(replace(body, char(13), ''), char(10), '\n')
    FROM messages
    WHERE id > $cursor AND team='$tl' AND to_agent='$al'
    ORDER BY id;
  "
}

# storage_export <team>
# Portable dump: one JSON object per message — {id,from,to,body,at,read_by:[agent...]}
# (read_by = the recipient when the message has been read). Used by migrate.
storage_export() {
  local team="$1" db tl
  db="$(agmsg_team_db_path "$team")"
  [ -f "$db" ] || return 0
  tl="$(agmsg_sqlesc "$team")"
  agmsg_sqlite "$db" "
    SELECT json_object('id',CAST(id AS TEXT),'from',from_agent,'to',to_agent,'body',body,'at',created_at,
      'read_by', CASE WHEN read_at IS NOT NULL THEN json_array(to_agent) ELSE json_array() END)
    FROM messages WHERE team='$tl' ORDER BY id;
  "
}

# storage_import <team>  (reads the export JSONL on stdin)
storage_import() {
  local team="$1" db init line from to body at readn ra
  db="$(agmsg_team_db_path "$team")"
  init="$(agmsg_skill_dir)/scripts/internal/init-db.sh"
  [ -f "$db" ] || bash "$init" "$team" >/dev/null
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    # jq @sh safely shell-quotes each field for eval; re-escaped for SQL below.
    eval "$(printf '%s' "$line" | jq -r '@sh "from=\(.from) to=\(.to) body=\(.body) at=\(.at) readn=\(.read_by|length|tostring)"')"
    ra="NULL"
    [ "${readn:-0}" -gt 0 ] && ra="'$(agmsg_sqlesc "$at")'"
    agmsg_sqlite "$db" "INSERT INTO messages (team,from_agent,to_agent,body,created_at,read_at) VALUES ('$(agmsg_sqlesc "$team")','$(agmsg_sqlesc "$from")','$(agmsg_sqlesc "$to")','$(agmsg_sqlesc "$body")','$(agmsg_sqlesc "$at")', $ra);"
  done
  # Reconstruct read cursors in THIS store's position space (ids are new here):
  # each agent's unread boundary = the highest id it has already read.
  local tl; tl="$(agmsg_sqlesc "$team")"
  agmsg_sqlite "$db" "
    INSERT INTO cursors (team, agent, pos)
      SELECT '$tl', to_agent, MAX(id) FROM messages
      WHERE team='$tl' AND read_at IS NOT NULL GROUP BY to_agent
    ON CONFLICT(team,agent) DO UPDATE SET pos=excluded.pos;
  " 2>/dev/null || true
}

# storage_purge <team> — remove this team's data from the CURRENT store. On the
# shared global store, delete only this team's rows; on a dedicated per-team
# store, remove its files. Call BEFORE flipping the team->driver mapping.
storage_purge() {
  local team="$1" dir global db tl
  dir="$(agmsg_team_storage_dir "$team")"
  global="$(agmsg_storage_dir)"
  tl="$(agmsg_sqlesc "$team")"
  if [ "$dir" = "$global" ]; then
    db="$(agmsg_team_db_path "$team")"
    if [ -f "$db" ]; then
      agmsg_sqlite "$db" "DELETE FROM messages WHERE team='$tl';" 2>/dev/null || true
      agmsg_sqlite "$db" "DELETE FROM events WHERE team='$tl';" 2>/dev/null || true
    fi
  else
    rm -f "$dir/messages.db" "$dir/messages.db-wal" "$dir/messages.db-shm"
  fi
}

# storage_history <team> <agent-or-empty> <limit>
# Emits one record per message: from <US> to <US> body <US> created_at <US> status
# (newest first; ● = unread, ○ = read). <limit> must be a validated integer.
storage_history() {
  local team="$1" agent="$2" limit="$3" db tl where
  db="$(agmsg_team_db_path "$team")"
  [ -f "$db" ] || return 0
  tl="$(agmsg_sqlesc "$team")"
  if [ -n "$agent" ]; then
    local al; al="$(agmsg_sqlesc "$agent")"
    where="WHERE team='$tl' AND (from_agent='$al' OR to_agent='$al')"
  else
    where="WHERE team='$tl'"
  fi
  agmsg_sqlite "$db" "
    SELECT from_agent || char(31) || to_agent || char(31) || replace(replace(body, char(10), '\n'), char(9), '\t') || char(31) || created_at || char(31) || CASE WHEN read_at IS NULL THEN '●' ELSE '○' END
    FROM messages $where ORDER BY created_at DESC LIMIT $limit;
  "
}
