#!/usr/bin/env bats

load test_helper

setup() {
  setup_test_env
}

teardown() {
  teardown_test_env
}

# --- agmsg_db_path() resolution ---

@test "storage: default path resolves under the skill dir" {
  source "$SCRIPTS/lib/storage.sh"
  unset AGMSG_STORAGE_PATH
  [ "$(agmsg_db_path)" = "$TEST_SKILL_DIR/db/messages.db" ]
}

@test "storage: AGMSG_STORAGE_PATH overrides the storage dir" {
  source "$SCRIPTS/lib/storage.sh"
  export AGMSG_STORAGE_PATH="$BATS_TEST_TMPDIR/store"
  [ "$(agmsg_db_path)" = "$BATS_TEST_TMPDIR/store/messages.db" ]
}

@test "storage: trailing slash on the override is normalized" {
  source "$SCRIPTS/lib/storage.sh"
  export AGMSG_STORAGE_PATH="$BATS_TEST_TMPDIR/store/"
  [ "$(agmsg_db_path)" = "$BATS_TEST_TMPDIR/store/messages.db" ]
}

# --- per-team storage resolution (Phase 2: env > team config > default) ---

@test "storage: a team with no storage backend uses the default global store" {
  source "$SCRIPTS/lib/storage.sh"
  unset AGMSG_STORAGE_PATH
  # no teams/<t>/config.json storage key => same path as the global default
  [ "$(agmsg_team_storage_driver noconf)" = "" ]
  [ "$(agmsg_team_db_path noconf)" = "$(agmsg_db_path)" ]
}

@test "storage: a team with a storage backend resolves to a per-team store dir" {
  source "$SCRIPTS/lib/storage.sh"
  unset AGMSG_STORAGE_PATH
  mkdir -p "$TEST_SKILL_DIR/teams/jt"
  printf '%s\n' '{"name":"jt","storage":"jsonl"}' > "$TEST_SKILL_DIR/teams/jt/config.json"
  [ "$(agmsg_team_storage_driver jt)" = "jsonl" ]
  [ "$(agmsg_team_db_path jt)" = "$TEST_SKILL_DIR/db/teams/jt/messages.db" ]
}

@test "storage: AGMSG_STORAGE_PATH still overrides per-team resolution" {
  source "$SCRIPTS/lib/storage.sh"
  export AGMSG_STORAGE_PATH="$BATS_TEST_TMPDIR/store"
  mkdir -p "$TEST_SKILL_DIR/teams/jt"
  printf '%s\n' '{"name":"jt","storage":"jsonl"}' > "$TEST_SKILL_DIR/teams/jt/config.json"
  [ "$(agmsg_team_db_path jt)" = "$BATS_TEST_TMPDIR/store/messages.db" ]
}

@test "storage: a per-team backend isolates a team's messages to its own store" {
  unset AGMSG_STORAGE_PATH
  mkdir -p "$TEST_SKILL_DIR/teams/jt"
  printf '%s\n' '{"name":"jt","storage":"sqlite"}' > "$TEST_SKILL_DIR/teams/jt/config.json"

  # send + read round-trip through the team's OWN store
  bash "$SCRIPTS/send.sh" jt alice bob "per-team hi"
  [ -f "$TEST_SKILL_DIR/db/teams/jt/messages.db" ]
  run bash "$SCRIPTS/inbox.sh" jt bob
  [ "$status" -eq 0 ]
  [[ "$output" =~ "per-team hi" ]]

  # the shared global store holds no rows for this team
  local g="$TEST_SKILL_DIR/db/messages.db"
  if [ -f "$g" ]; then
    [ "$(sqlite3 "$g" "SELECT COUNT(*) FROM messages WHERE team='jt';")" -eq 0 ]
  fi
}

# --- storage driver facade + sqlite driver (phase 2b) ---

@test "storage driver: defaults to sqlite when the team has no backend set" {
  source "$SCRIPTS/lib/storage.sh"
  export AGMSG_STORAGE_PATH="$BATS_TEST_TMPDIR/store"
  agmsg_storage_load noconf
  [ "$_AGMSG_LOADED_DRIVER" = "sqlite" ]
  [ -n "$(type -t storage_send)" ]
}

@test "storage driver (sqlite): facade send/list/mark/history round-trip" {
  source "$SCRIPTS/lib/storage.sh"
  export AGMSG_STORAGE_PATH="$BATS_TEST_TMPDIR/store"
  agmsg_storage_load t

  storage_send t alice bob "drv one"
  storage_send t alice bob "drv two"

  run storage_list_unread t bob
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | grep -c 'drv ')" -eq 2 ]

  storage_mark_read t bob
  run storage_list_unread t bob
  [ -z "$output" ]
  # read-state recorded as append-only events (dual-write)
  [ "$(sqlite3 "$AGMSG_STORAGE_PATH/messages.db" "SELECT COUNT(*) FROM events WHERE type='message_read';")" -eq 2 ]

  run storage_history t "" 20
  [ "$status" -eq 0 ]
  [[ "$output" =~ "drv one" ]]
  [[ "$output" =~ "drv two" ]]
}

@test "storage use: sets a team's backend via the config-write seam" {
  source "$SCRIPTS/lib/storage.sh"
  unset AGMSG_STORAGE_PATH
  mkdir -p "$TEST_SKILL_DIR/teams/ut"
  printf '%s\n' '{"name":"ut","agents":{}}' > "$TEST_SKILL_DIR/teams/ut/config.json"

  bash "$SCRIPTS/storage.sh" use jsonl ut
  [ "$(agmsg_team_storage_driver ut)" = "jsonl" ]
  # existing config keys are preserved (json_set, not overwrite)
  [ "$(agmsg_sqlite_mem "SELECT json_extract(readfile('$TEST_SKILL_DIR/teams/ut/config.json'),'\$.name');")" = "ut" ]
}

@test "storage driver (sqlite): watch_tip/after stream only messages past the cursor" {
  source "$SCRIPTS/lib/storage.sh"
  export AGMSG_STORAGE_PATH="$BATS_TEST_TMPDIR/store"
  agmsg_storage_load t
  storage_send t alice bob "w1"
  local tip; tip="$(storage_watch_tip t)"
  storage_send t alice bob "w2"
  run storage_watch_after t bob "$tip"
  [ "$status" -eq 0 ]
  [[ "$output" =~ "w2" ]]
  [[ ! "$output" =~ "w1" ]]
  # first field is a numeric position past the cursor
  local pos; pos="$(printf '%s' "$output" | head -1 | cut -d$'\x1f' -f1)"
  [ "$pos" -gt "$tip" ]
}

@test "storage driver (jsonl): watch_tip/after stream only messages past the cursor" {
  if ! command -v jq >/dev/null 2>&1; then skip "jq not installed"; fi
  source "$SCRIPTS/lib/storage.sh"
  unset AGMSG_STORAGE_PATH
  mkdir -p "$TEST_SKILL_DIR/teams/jw"
  printf '%s\n' '{"name":"jw","storage":"jsonl"}' > "$TEST_SKILL_DIR/teams/jw/config.json"
  agmsg_storage_load jw
  storage_send jw alice bob "w1"
  local tip; tip="$(storage_watch_tip jw)"
  storage_send jw alice bob "w2"
  run storage_watch_after jw bob "$tip"
  [ "$status" -eq 0 ]
  [[ "$output" =~ "w2" ]]
  [[ ! "$output" =~ "w1" ]]
}

@test "storage driver (sqlite): read cursor get/set round-trip, per-pair" {
  source "$SCRIPTS/lib/storage.sh"
  export AGMSG_STORAGE_PATH="$BATS_TEST_TMPDIR/store"
  agmsg_storage_load t
  [ "$(storage_get_cursor t bob)" = "0" ]
  storage_set_cursor t bob 42
  [ "$(storage_get_cursor t bob)" = "42" ]
  [ "$(storage_get_cursor t alice)" = "0" ]   # per-pair isolation
  storage_set_cursor t bob 99                   # upsert
  [ "$(storage_get_cursor t bob)" = "99" ]
}

@test "storage driver (jsonl): read cursor get/set round-trip, per-pair" {
  if ! command -v jq >/dev/null 2>&1; then skip "jq not installed"; fi
  source "$SCRIPTS/lib/storage.sh"
  unset AGMSG_STORAGE_PATH
  mkdir -p "$TEST_SKILL_DIR/teams/jc"
  printf '%s\n' '{"name":"jc","storage":"jsonl"}' > "$TEST_SKILL_DIR/teams/jc/config.json"
  agmsg_storage_load jc
  [ "$(storage_get_cursor jc bob)" = "0" ]
  storage_set_cursor jc bob 7
  [ "$(storage_get_cursor jc bob)" = "7" ]
  [ "$(storage_get_cursor jc alice)" = "0" ]
  storage_set_cursor jc bob 12
  [ "$(storage_get_cursor jc bob)" = "12" ]
}

@test "storage migration: seeds the cursor from existing read_at (no re-delivery on upgrade)" {
  source "$SCRIPTS/lib/storage.sh"
  export AGMSG_STORAGE_PATH="$BATS_TEST_TMPDIR/store"
  # Simulate a pre-migration store an older version left behind: messages already
  # read (read_at set), but no cursor and user_version 0.
  bash "$SCRIPTS/internal/init-db.sh" >/dev/null
  local db="$AGMSG_STORAGE_PATH/messages.db"
  sqlite3 "$db" "INSERT INTO messages (team,from_agent,to_agent,body,read_at) VALUES
    ('t','a','bob','old1','2026-01-01T00:00:00Z'),
    ('t','a','bob','old2','2026-01-01T00:00:01Z');"
  sqlite3 "$db" "DELETE FROM cursors; PRAGMA user_version=0;"

  # First new-version read: the migration seeds the cursor from read_at, so the
  # already-read history is NOT re-delivered.
  run bash "$SCRIPTS/inbox.sh" t bob
  [ "$status" -eq 0 ]
  [[ "$output" =~ "No new messages" ]]
  [ "$(sqlite3 "$db" "PRAGMA user_version;")" = "1" ]
  [ "$(sqlite3 "$db" "SELECT pos FROM cursors WHERE team='t' AND agent='bob';")" = "2" ]

  # A message sent AFTER the upgrade is still delivered.
  bash "$SCRIPTS/send.sh" t a bob "new-after-upgrade"
  run bash "$SCRIPTS/inbox.sh" t bob
  [[ "$output" =~ "new-after-upgrade" ]]
}

@test "storage migrate: carries messages + read-state to jsonl and purges the source" {
  if ! command -v jq >/dev/null 2>&1; then skip "jq not installed"; fi
  source "$SCRIPTS/lib/storage.sh"
  unset AGMSG_STORAGE_PATH

  # default (global sqlite) team: m1 read, m2 unread
  bash "$SCRIPTS/send.sh" mg alice bob "m1"
  bash "$SCRIPTS/inbox.sh" mg bob >/dev/null      # marks m1 read
  bash "$SCRIPTS/send.sh" mg alice bob "m2"        # unread

  bash "$SCRIPTS/storage.sh" migrate jsonl mg

  # mapping flipped
  [ "$(agmsg_team_storage_driver mg)" = "jsonl" ]
  # source purged: no mg rows left in the global sqlite store
  [ "$(sqlite3 "$TEST_SKILL_DIR/db/messages.db" "SELECT COUNT(*) FROM messages WHERE team='mg';")" -eq 0 ]
  # both messages now in the jsonl store
  [ "$(wc -l < "$TEST_SKILL_DIR/db/teams/mg/messages.jsonl" | tr -d ' ')" -eq 2 ]
  # backup file retained
  ls "$TEST_SKILL_DIR/db/migrate-sqlite-to-jsonl.jsonl" >/dev/null

  # read-state preserved: only m2 is still unread for bob
  run bash "$SCRIPTS/inbox.sh" mg bob
  [[ "$output" =~ "m2" ]]
  [[ ! "$output" =~ "m1" ]]
}

@test "rename-team: carries a per-team jsonl store to the new name" {
  if ! command -v jq >/dev/null 2>&1; then skip "jq not installed"; fi
  source "$SCRIPTS/lib/storage.sh"
  unset AGMSG_STORAGE_PATH
  bash "$SCRIPTS/join.sh" oldteam alice claude-code "/tmp/agmsg-rt-proj" >/dev/null
  bash "$SCRIPTS/storage.sh" use jsonl oldteam
  bash "$SCRIPTS/send.sh" oldteam alice bob "keep me"
  [ -f "$TEST_SKILL_DIR/db/teams/oldteam/messages.jsonl" ]

  bash "$SCRIPTS/rename-team.sh" oldteam newteam

  [ ! -d "$TEST_SKILL_DIR/db/teams/oldteam" ]
  [ -f "$TEST_SKILL_DIR/db/teams/newteam/messages.jsonl" ]
  [ "$(agmsg_team_storage_driver newteam)" = "jsonl" ]
  run bash "$SCRIPTS/inbox.sh" newteam bob
  [ "$status" -eq 0 ]
  [[ "$output" =~ "keep me" ]]
}

@test "rename-team: rewrites the team column in a per-team sqlite store" {
  source "$SCRIPTS/lib/storage.sh"
  unset AGMSG_STORAGE_PATH
  bash "$SCRIPTS/join.sh" sqold alice claude-code "/tmp/agmsg-rt-proj2" >/dev/null
  bash "$SCRIPTS/storage.sh" use sqlite sqold
  bash "$SCRIPTS/send.sh" sqold alice bob "sq keep"
  [ -f "$TEST_SKILL_DIR/db/teams/sqold/messages.db" ]

  bash "$SCRIPTS/rename-team.sh" sqold sqnew

  [ -f "$TEST_SKILL_DIR/db/teams/sqnew/messages.db" ]
  # queries filter by team, so the column must have been rewritten to the new name
  run bash "$SCRIPTS/inbox.sh" sqnew bob
  [ "$status" -eq 0 ]
  [[ "$output" =~ "sq keep" ]]
}

@test "storage migrate: no-op when already on the target backend" {
  source "$SCRIPTS/lib/storage.sh"
  unset AGMSG_STORAGE_PATH
  bash "$SCRIPTS/send.sh" already alice bob "x"
  run bash "$SCRIPTS/storage.sh" migrate sqlite already
  [ "$status" -eq 0 ]
  [[ "$output" =~ "already on sqlite" ]]
}

@test "storage driver (jsonl): per-team send/list/mark/history via the facade" {
  if ! command -v jq >/dev/null 2>&1; then skip "jq not installed"; fi
  unset AGMSG_STORAGE_PATH
  mkdir -p "$TEST_SKILL_DIR/teams/jt"
  printf '%s\n' '{"name":"jt","storage":"jsonl"}' > "$TEST_SKILL_DIR/teams/jt/config.json"
  local d="$TEST_SKILL_DIR/db/teams/jt"

  bash "$SCRIPTS/send.sh" jt alice bob "json one"
  bash "$SCRIPTS/send.sh" jt alice bob "json two"
  # content lands in the team's jsonl log — NOT a sqlite db
  [ -f "$d/messages.jsonl" ]
  [ ! -f "$d/messages.db" ]
  [ "$(wc -l < "$d/messages.jsonl" | tr -d ' ')" -eq 2 ]

  run bash "$SCRIPTS/inbox.sh" jt bob
  [ "$status" -eq 0 ]
  [[ "$output" =~ "json one" ]]
  [[ "$output" =~ "json two" ]]
  # read-state is append-only message_read events
  [ -f "$d/events.jsonl" ]
  [ "$(grep -c message_read "$d/events.jsonl")" -eq 2 ]

  # re-read: nothing unread now
  run bash "$SCRIPTS/inbox.sh" jt bob
  [[ "$output" =~ "No new messages" ]]

  # history shows both
  run bash "$SCRIPTS/history.sh" jt
  [ "$status" -eq 0 ]
  [[ "$output" =~ "json one" ]]
  [[ "$output" =~ "json two" ]]
}

# --- agmsg_db_path() Windows path conversion (#197) ---

@test "storage: agmsg_db_path applies cygpath -m on Windows so sqlite3.exe can open it (#197)" {
  # The native sqlite3.exe cannot open a Git Bash /c/... path; cygpath -m maps it
  # to the mixed C:/... form both the shell and sqlite3.exe accept. cygpath is
  # absent off Windows, so inject a shim on PATH to exercise the branch.
  local bindir="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$bindir"
  cat > "$bindir/cygpath" <<'SH'
#!/usr/bin/env bash
# Minimal stand-in: `cygpath -m /c/x` -> C:/x (BSD- and GNU-sed portable).
shift  # drop the -m flag
printf '%s\n' "$1" | sed -E 's#^/c/#C:/#'
SH
  chmod +x "$bindir/cygpath"
  run env PATH="$bindir:$PATH" AGMSG_STORAGE_PATH="/c/Users/test/db" \
    bash -c 'source "'"$SCRIPTS"'/lib/storage.sh"; agmsg_db_path'
  [ "$status" -eq 0 ]
  [ "$output" = "C:/Users/test/db/messages.db" ]
}

@test "storage: agmsg_db_path is a no-op without cygpath (off Windows)" {
  source "$SCRIPTS/lib/storage.sh"
  export AGMSG_STORAGE_PATH="$BATS_TEST_TMPDIR/store"
  # cygpath is absent on the test host, so the path is returned unchanged.
  [ "$(agmsg_db_path)" = "$BATS_TEST_TMPDIR/store/messages.db" ]
}

# --- init-db.sh honoring the override ---

@test "storage: init-db creates the db at the overridden path (and makes the dir)" {
  local custom="$BATS_TEST_TMPDIR/nested/store"
  [ ! -d "$custom" ]
  AGMSG_STORAGE_PATH="$custom" bash "$SCRIPTS/internal/init-db.sh"
  [ -f "$custom/messages.db" ]
}

# --- end-to-end roundtrip through the override ---

@test "storage: send and inbox share the overridden db" {
  export AGMSG_STORAGE_PATH="$BATS_TEST_TMPDIR/store"
  bash "$SCRIPTS/send.sh" testteam alice bob "hi via override"
  [ -f "$AGMSG_STORAGE_PATH/messages.db" ]

  run bash "$SCRIPTS/inbox.sh" testteam bob
  [ "$status" -eq 0 ]
  [[ "$output" =~ "hi via override" ]]
}

# --- append-only read-state events (transition: dual-write with read_at) ---

@test "storage: reading appends message_read events and dual-writes read_at" {
  export AGMSG_STORAGE_PATH="$BATS_TEST_TMPDIR/store"
  bash "$SCRIPTS/send.sh" testteam alice bob "msg one"
  bash "$SCRIPTS/send.sh" testteam alice bob "msg two"
  local db="$AGMSG_STORAGE_PATH/messages.db"

  # read-state log starts empty
  [ "$(sqlite3 "$db" "SELECT COUNT(*) FROM events;")" -eq 0 ]

  run bash "$SCRIPTS/inbox.sh" testteam bob
  [ "$status" -eq 0 ]
  # dual-write: read_at set AND an append-only message_read event per message
  [ "$(sqlite3 "$db" "SELECT COUNT(*) FROM messages WHERE read_at IS NOT NULL;")" -eq 2 ]
  [ "$(sqlite3 "$db" "SELECT COUNT(*) FROM events WHERE type='message_read' AND team='testteam' AND agent='bob';")" -eq 2 ]

  # re-reading is a no-op: no duplicate read-state events
  bash "$SCRIPTS/inbox.sh" testteam bob
  [ "$(sqlite3 "$db" "SELECT COUNT(*) FROM events;")" -eq 2 ]
}

@test "storage: message content is never written to the events table (read-state only)" {
  export AGMSG_STORAGE_PATH="$BATS_TEST_TMPDIR/store"
  bash "$SCRIPTS/send.sh" testteam alice bob "secret body"
  bash "$SCRIPTS/inbox.sh" testteam bob >/dev/null
  local db="$AGMSG_STORAGE_PATH/messages.db"

  # events holds ONLY read-state rows — no other event types, no body column.
  # (Guards against the storage-axis regression of moving content into events.)
  [ -z "$(sqlite3 "$db" "SELECT type FROM events WHERE type<>'message_read';")" ]
  [ "$(sqlite3 "$db" "SELECT COUNT(*) FROM messages WHERE body='secret body';")" -eq 1 ]
}

@test "storage: stop-hook delivery works when the default db dir is absent but the override is populated" {
  local store="$BATS_TEST_TMPDIR/store"
  local project="/tmp/agmsg-storage-test-proj"

  # Register an agent so check-inbox can resolve identity via whoami.
  bash "$SCRIPTS/join.sh" testteam alice claude-code "$project"

  # A message addressed to alice lives only in the overridden store.
  AGMSG_STORAGE_PATH="$store" bash "$SCRIPTS/send.sh" testteam bob alice "via override store"

  # Simulate a clean install whose default skill db dir never existed.
  rm -rf "$TEST_SKILL_DIR/db"

  # Stop-hook delivery must still succeed (exit 0) and surface the message —
  # the cooldown marker now lives in run/, not the (absent) db dir.
  run bash -c "echo '{}' | AGMSG_STORAGE_PATH='$store' bash '$SCRIPTS/check-inbox.sh' claude-code '$project'"
  [ "$status" -eq 0 ]
  [[ "$output" =~ "via override store" ]]
}

@test "storage: default db is untouched when the override is set" {
  # The default store was initialized in setup; writing through an override
  # must not add rows to it.
  export AGMSG_STORAGE_PATH="$BATS_TEST_TMPDIR/store"
  bash "$SCRIPTS/send.sh" testteam alice bob "isolated"

  local default_count
  default_count=$(sqlite3 "$TEST_SKILL_DIR/db/messages.db" "SELECT COUNT(*) FROM messages;")
  [ "$default_count" -eq 0 ]
}

@test "storage: agmsg_sqlite sets a busy timeout without polluting output" {
  # .timeout (not PRAGMA) so the timeout value is never echoed into results.
  source "$SCRIPTS/lib/storage.sh"
  run agmsg_sqlite ":memory:" "SELECT 'only-this';"
  [ "$status" -eq 0 ]
  [ "$output" = "only-this" ]
}

@test "storage: agmsg_sqlite emits a raw char(31) separator, not caret '^_' (#102)" {
  # sqlite3 >= 3.50 renders control bytes with caret notation by default, which
  # would turn the char(31) record separator into the two chars "^_" and break
  # the IFS=$'\x1f' field splitting in inbox/history/check-inbox + the watch
  # stream. agmsg_sqlite must pass -escape off so the byte stays raw. On older
  # sqlite3 the byte is raw anyway, so this holds on every supported version.
  source "$SCRIPTS/lib/storage.sh"
  run agmsg_sqlite ":memory:" "SELECT 'a'||char(31)||'b';"
  [ "$status" -eq 0 ]
  printf '%s' "$output" | grep -q $'\x1f'
  ! printf '%s' "$output" | grep -q '\^_'
}

@test "send: concurrent fan-out to N recipients all land (no SQLITE_BUSY)" {
  # Without a busy_timeout, concurrent writers fail with SQLITE_BUSY(5) and the
  # sends silently drop. With the wrapper they wait and all land. See #114.
  local x
  for x in 1 2 3 4 5 6 7 8 9 10; do
    ( bash "$SCRIPTS/send.sh" team leader "tgt$x" "job $x" >/dev/null 2>&1 ) &
  done
  wait
  local n
  n=$(sqlite3 "$TEST_SKILL_DIR/db/messages.db" \
    "SELECT COUNT(*) FROM messages WHERE from_agent='leader';")
  [ "$n" -eq 10 ]
}

@test "send: concurrent fan-out to a FRESH (uninitialized) store all lands" {
  # No init-db first — every send races to initialize an override store that
  # doesn't exist yet. Without idempotent init + INSERT retry, the losers abort
  # on "already exists" / "no such table" and drop. See #114.
  export AGMSG_STORAGE_PATH="$BATS_TEST_TMPDIR/freshstore"
  local x
  for x in 1 2 3 4 5 6 7 8 9 10; do
    ( bash "$SCRIPTS/send.sh" team leader "tgt$x" "job $x" >/dev/null 2>&1 ) &
  done
  wait
  local n
  n=$(sqlite3 "$AGMSG_STORAGE_PATH/messages.db" "SELECT COUNT(*) FROM messages;")
  [ "$n" -eq 10 ]
}
