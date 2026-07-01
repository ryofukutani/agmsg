#!/usr/bin/env bash
# jsonl storage driver — append-only file backend (opt-in, per-team).
#
# Two append-only logs under the team's store dir (db/teams/<team>/):
#   messages.jsonl — one JSON object per line: {id,team,from,to,body,at}  (CONTENT)
#   events.jsonl   — one JSON object per line: {type:"message_read",team,agent,msg_id,at}
# Read-state is the append-only message_read event (there is no read_at here);
# unread = a message to <agent> with no matching message_read event. Symmetric
# with the sqlite backend (content + read-state events), different physical form.
#
# Engine: jq (zero extra daemon). A duckdb fast path for very large logs is a
# follow-up (#207). Sourced by agmsg_storage_load(); assumes lib/storage.sh
# helpers (agmsg_team_storage_dir, agmsg_sqlite_mem) are in scope.

# Fail loudly if the engine is missing — a team opting into jsonl needs jq.
storage_check() {
  command -v jq >/dev/null 2>&1 || {
    echo "agmsg: the jsonl storage backend requires 'jq' (not found on PATH)" >&2
    return 1
  }
}

_jsonl_msgs()   { printf '%s\n' "$(agmsg_team_storage_dir "$1")/messages.jsonl"; }
_jsonl_events() { printf '%s\n' "$(agmsg_team_storage_dir "$1")/events.jsonl"; }

# storage_exists <team> — has this team's content log been created?
storage_exists() { [ -f "$(_jsonl_msgs "$1")" ]; }

# storage_send <team> <from> <to> <body>
storage_send() {
  storage_check || return 1
  local team="$1" from="$2" to="$3" body="$4" dir id at
  dir="$(agmsg_team_storage_dir "$team")"; mkdir -p "$dir"
  id="$(agmsg_sqlite_mem "SELECT lower(hex(randomblob(16)));")"
  at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  jq -cn --arg id "$id" --arg team "$team" --arg from "$from" --arg to "$to" \
        --arg body "$body" --arg at "$at" \
        '{id:$id,team:$team,from:$from,to:$to,body:$body,at:$at}' >> "$dir/messages.jsonl"
}

# storage_list_unread <team> <agent>
# Records: from <US> body <US> at  (oldest first). Unread = to==agent with no
# message_read event. Body newlines/tabs escaped to keep one record per line.
storage_list_unread() {
  storage_check || return 1
  local team="$1" agent="$2" msgs evs
  msgs="$(_jsonl_msgs "$team")"; evs="$(_jsonl_events "$team")"
  [ -f "$msgs" ] || return 0
  [ -f "$evs" ] || evs=/dev/null
  jq -rn --arg agent "$agent" --slurpfile msgs "$msgs" --slurpfile evs "$evs" '
    ([ $evs[] | select(.type=="message_read" and .agent==$agent) | .msg_id ] | unique) as $read
    | [ $msgs[] | select(.to==$agent and ((.id) as $i | ($read | index($i)) | not)) ]
    | sort_by(.at)[]
    | [ .from, (.body | gsub("\n";"\\n") | gsub("\t";"\\t")), .at ] | join("\u001f")
  '
}

# storage_mark_read <team> <agent> — append a message_read event per unread message.
storage_mark_read() {
  storage_check || return 1
  local team="$1" agent="$2" dir msgs evs at id
  dir="$(agmsg_team_storage_dir "$team")"
  msgs="$(_jsonl_msgs "$team")"; evs="$(_jsonl_events "$team")"
  [ -f "$msgs" ] || return 0
  local evread="$evs"; [ -f "$evread" ] || evread=/dev/null
  at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  mkdir -p "$dir"
  jq -rn --arg agent "$agent" --slurpfile msgs "$msgs" --slurpfile evs "$evread" '
    ([ $evs[] | select(.type=="message_read" and .agent==$agent) | .msg_id ] | unique) as $read
    | $msgs[] | select(.to==$agent and ((.id) as $i | ($read | index($i)) | not)) | .id
  ' | while IFS= read -r id; do
    [ -n "$id" ] || continue
    jq -cn --arg team "$team" --arg agent "$agent" --arg id "$id" --arg at "$at" \
          '{type:"message_read",team:$team,agent:$agent,msg_id:$id,at:$at}' >> "$evs"
  done
}

# Current jsonl schema/data version. Bump when adding a migration step.
_JSONL_SCHEMA_VERSION=1

# storage_ensure_schema <team> — version-gated migration, mirroring the sqlite
# driver. The jsonl backend is new (no pre-existing stores) and its read-state
# is already event-based with the cursor written on consume, so there is no data
# to back-fill yet; this just records the version. Gated by a .schema-version
# file so it runs once.
storage_ensure_schema() {
  local team="$1" dir vf v
  dir="$(agmsg_team_storage_dir "$team")"
  [ -d "$dir" ] || return 0
  vf="$dir/.schema-version"
  v=0; [ -f "$vf" ] && v="$(cat "$vf" 2>/dev/null || echo 0)"
  case "$v" in ''|*[!0-9]*) v=0 ;; esac
  [ "$v" -ge "$_JSONL_SCHEMA_VERSION" ] && return 0
  printf '%s\n' "$_JSONL_SCHEMA_VERSION" > "$vf" 2>/dev/null || true
}

# storage_consume <team> <agent> <pos> — mark everything up to <pos> consumed:
# append message_read events for messages on lines <= <pos> to <agent> not yet
# read, then advance the read cursor (forward only). Bounded by <pos> so the
# watcher never records past an undelivered message (#67).
storage_consume() {
  storage_check || return 1
  local team="$1" agent="$2" pos="$3" dir msgs evs evread at cur
  dir="$(agmsg_team_storage_dir "$team")"
  msgs="$(_jsonl_msgs "$team")"
  [ -f "$msgs" ] || return 0
  case "$pos" in ''|*[!0-9]*) return 0 ;; esac
  evs="$(_jsonl_events "$team")"; evread="$evs"; [ -f "$evread" ] || evread=/dev/null
  at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"; mkdir -p "$dir"
  jq -r --arg agent "$agent" --argjson pos "$pos" --slurpfile evs "$evread" '
    ([ $evs[] | select(.type=="message_read" and .agent==$agent) | .msg_id ] | unique) as $read
    | select((input_line_number <= $pos) and .to == $agent and ((.id) as $i | ($read | index($i)) | not))
    | .id
  ' "$msgs" 2>/dev/null | while IFS= read -r id; do
    [ -n "$id" ] || continue
    jq -cn --arg team "$team" --arg agent "$agent" --arg id "$id" --arg at "$at" \
          '{type:"message_read",team:$team,agent:$agent,msg_id:$id,at:$at}' >> "$evs"
  done
  cur="$(storage_get_cursor "$team" "$agent")"
  [ "$pos" -gt "${cur:-0}" ] && storage_set_cursor "$team" "$agent" "$pos"
  return 0
}

# Read cursor file: <team-store-dir>/cursors, lines "<team>\t<agent>\t<pos>".
_jsonl_cursors() { printf '%s\n' "$(agmsg_team_storage_dir "$1")/cursors"; }

# storage_get_cursor <team> <agent> — the read cursor (unread boundary), 0 if none.
storage_get_cursor() {
  local team="$1" agent="$2" f
  f="$(_jsonl_cursors "$team")"
  [ -f "$f" ] || { echo 0; return 0; }
  awk -F'\t' -v t="$team" -v a="$agent" '$1==t && $2==a {p=$3} END{print (p==""?0:p)}' "$f"
}

# storage_set_cursor <team> <agent> <pos> — persist the read cursor (rewrite the file).
storage_set_cursor() {
  local team="$1" agent="$2" pos="$3" dir f tmp
  dir="$(agmsg_team_storage_dir "$team")"; mkdir -p "$dir"
  f="$dir/cursors"; tmp="$f.tmp.$$"
  case "$pos" in ''|*[!0-9]*) pos=0 ;; esac
  { [ -f "$f" ] && awk -F'\t' -v t="$team" -v a="$agent" '!($1==t && $2==a)' "$f"
    printf '%s\t%s\t%s\n' "$team" "$agent" "$pos"; } > "$tmp"
  mv "$tmp" "$f"
}

# storage_watch_tip <team> — high-water cursor = number of message lines.
storage_watch_tip() {
  local msgs; msgs="$(_jsonl_msgs "$1")"
  [ -f "$msgs" ] || { echo 0; return 0; }
  wc -l < "$msgs" | tr -d ' '
}

# storage_watch_after <team> <agent> <cursor>
# Emit new messages to <agent> on lines after <cursor>, as:
#   <pos> <US> <ts> <US> <team> <US> <from> <US> <to> <US> <body>
# <pos> is the 1-based line number (the cursor type); CR stripped, newlines -> "\n".
storage_watch_after() {
  storage_check || return 1
  local team="$1" agent="$2" cursor="$3" msgs
  msgs="$(_jsonl_msgs "$team")"
  [ -f "$msgs" ] || return 0
  case "$cursor" in ''|*[!0-9]*) cursor=0 ;; esac
  jq -r --arg agent "$agent" --argjson cursor "$cursor" '
    select((input_line_number > $cursor) and .to == $agent)
    | [ (input_line_number|tostring), .at, .team, .from, .to,
        (.body | gsub("\r";"") | gsub("\n";"\\n")) ] | join("\u001f")
  ' "$msgs"
}

# storage_export <team>
# Portable dump: one JSON object per message — {id,from,to,body,at,read_by:[agent...]}.
storage_export() {
  storage_check || return 1
  local team="$1" msgs evs
  msgs="$(_jsonl_msgs "$team")"; evs="$(_jsonl_events "$team")"
  [ -f "$msgs" ] || return 0
  [ -f "$evs" ] || evs=/dev/null
  jq -c --slurpfile evs "$evs" '
    . as $m
    | {id:.id, from:.from, to:.to, body:.body, at:.at,
       read_by: [ $evs[] | select(.type=="message_read" and .msg_id==$m.id) | .agent ]}
  ' "$msgs"
}

# storage_import <team>  (reads the export JSONL on stdin)
storage_import() {
  storage_check || return 1
  local team="$1" dir line
  dir="$(agmsg_team_storage_dir "$team")"; mkdir -p "$dir"
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    printf '%s\n' "$line" | jq -c --arg team "$team" '{id,team:$team,from,to,body,at}' >> "$dir/messages.jsonl"
    printf '%s\n' "$line" | jq -c --arg team "$team" '.id as $id | (.read_by // [])[] | {type:"message_read",team:$team,agent:.,msg_id:$id,at:""}' >> "$dir/events.jsonl"
  done
  # Reconstruct read cursors in THIS store's position space (line numbers here):
  # each agent's unread boundary = the highest line it has already read.
  local msgs evs; msgs="$dir/messages.jsonl"; evs="$dir/events.jsonl"
  if [ -f "$msgs" ] && [ -f "$evs" ]; then
    jq -r --slurpfile evs "$evs" '
      ([ $evs[] | select(.type=="message_read") | (.msg_id + " " + .agent) ] | unique) as $read
      | select( ((.id + " " + .to) as $k | ($read | index($k))) )
      | (input_line_number|tostring) + "\t" + .to
    ' "$msgs" 2>/dev/null \
    | awk -F'\t' '{ if ($1+0 > m[$2]) m[$2]=$1 } END { for (a in m) print a "\t" m[a] }' \
    | while IFS="$(printf '\t')" read -r _a _p; do
        [ -n "$_a" ] && storage_set_cursor "$team" "$_a" "$_p"
      done
  fi
}

# storage_purge <team> — remove this team's append-only logs.
storage_purge() {
  local team="$1" dir
  dir="$(agmsg_team_storage_dir "$team")"
  rm -f "$dir/messages.jsonl" "$dir/events.jsonl"
}

# storage_history <team> <agent-or-empty> <limit>
# Records: from <US> to <US> body <US> at <US> status  (newest first; ● unread, ○ read).
storage_history() {
  storage_check || return 1
  local team="$1" agent="$2" limit="$3" msgs evs
  msgs="$(_jsonl_msgs "$team")"; evs="$(_jsonl_events "$team")"
  [ -f "$msgs" ] || return 0
  [ -f "$evs" ] || evs=/dev/null
  jq -rn --arg agent "$agent" --argjson limit "$limit" \
        --slurpfile msgs "$msgs" --slurpfile evs "$evs" '
    ([ $evs[] | select(.type=="message_read") | (.msg_id + " " + .agent) ] | unique) as $read
    | [ $msgs[] | select($agent=="" or .from==$agent or .to==$agent) ]
    | sort_by(.at) | reverse | .[0:$limit][]
    | ((.id + " " + .to) as $k | (if ($read | index($k)) then "○" else "●" end)) as $st
    | [ .from, .to, (.body | gsub("\n";"\\n") | gsub("\t";"\\t")), .at, $st ] | join("\u001f")
  '
}
