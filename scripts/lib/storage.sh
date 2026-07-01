#!/usr/bin/env bash
# storage.sh — resolve the path to the sqlite message store (messages.db).
#
# Scope: the storage axis only — where messages are persisted. This is NOT a
# storage-driver interface; it just centralizes the path resolution that was
# previously duplicated across the script set.
#
# Resolution order:
#   1. AGMSG_STORAGE_PATH — directory that holds messages.db (env override)
#   2. SKILL_DIR env var  — set by callers before sourcing (sandbox fallback)
#   3. BASH_SOURCE[0]     — derive from this file's own path (standard case)
#
# [seam] A config-file layer is expected to slot in between the env override
# and the built-in default once the storage-driver work lands; the intended
# full order is env > config > default. Keep that logic here so call sites
# stay unchanged.

# Resolve the skill directory — the install root that holds db/ and teams/.
agmsg_skill_dir() {
  local lib_dir
  if [ -n "${BASH_SOURCE[0]:-}" ]; then
    lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    (cd "$lib_dir/../.." && pwd)
  elif [ -n "${SKILL_DIR:-}" ]; then
    # BASH_SOURCE empty — e.g. Claude Code sandbox runs Bash via pipe/eval
    # so BASH_SOURCE is not populated. Fall back to SKILL_DIR which the
    # calling script resolves from $0 (which IS populated correctly).
    printf '%s\n' "$SKILL_DIR"
  else
    echo "Error: cannot resolve skill dir (BASH_SOURCE and SKILL_DIR both empty)" >&2
    return 1
  fi
}

# Echo the directory that holds (or will hold) the (default/global) message store.
agmsg_storage_dir() {
  if [ -n "${AGMSG_STORAGE_PATH:-}" ]; then
    # Strip a single trailing slash for a stable join with the filename.
    printf '%s\n' "${AGMSG_STORAGE_PATH%/}"
    return
  fi
  local skill_dir; skill_dir="$(agmsg_skill_dir)" || return 1
  printf '%s\n' "$skill_dir/db"
}

# Echo the full path to messages.db, in a form the sqlite3 binary can open.
# On Windows, sqlite3.exe is a native binary that cannot open a Git Bash path
# like /c/Users/.../db/messages.db: open() fails, so inbox/send/watch all fail
# to reach the store and the team goes silent (#197, reported by vhsvhafmwf).
# cygpath -m converts to the mixed C:/Users/.../db/messages.db form that BOTH
# the shell's `[ -f "$db" ]` test AND sqlite3.exe accept — unlike -w's backslash
# form (C:\Users\...), which the surrounding shell quoting/tests mishandle.
# No-op off Windows (cygpath absent). Mirrors agmsg_sql_readfile_path's pattern.
agmsg_db_path() {
  local db
  db="$(agmsg_storage_dir)/messages.db"
  if command -v cygpath >/dev/null 2>&1; then
    db=$(cygpath -m "$db" 2>/dev/null || printf '%s' "$db")
  fi
  printf '%s\n' "$db"
}

# --- Per-team storage resolution (Phase 2: per-team backend) -----------------
# Teams default to the shared global store (existing behavior, zero migration).
# A team opts into its own store by setting a "storage" backend in its
# teams/<team>/config.json; resolution then routes that team to a dedicated
# directory under <skill>/db/teams/<team>/. This slots into the documented
# [seam] above: env (AGMSG_STORAGE_PATH) > team config > built-in default.
# These helpers are additive — existing call sites keep using agmsg_db_path()
# until they are migrated to the team-aware path in a later step.

# teams/ directory under the skill root.
agmsg_teams_dir() {
  local skill_dir; skill_dir="$(agmsg_skill_dir)" || return 1
  printf '%s\n' "$skill_dir/teams"
}

# Storage backend selected for <team>, read from teams/<team>/config.json
# ($.storage). Empty output => no per-team backend set => default (sqlite, global).
agmsg_team_storage_driver() {
  local team="$1" cfg driver
  [ -n "$team" ] || return 0
  cfg="$(agmsg_teams_dir)/$team/config.json" || return 0
  [ -f "$cfg" ] || return 0
  driver="$(agmsg_sqlite_mem \
    "SELECT COALESCE(json_extract(readfile('$(agmsg_sql_readfile_path "$cfg")'), '\$.storage'), '');" \
    2>/dev/null)"
  [ "$driver" = "null" ] && driver=""
  printf '%s' "$driver"
}

# Directory holding <team>'s store. env override > per-team (when a backend is
# configured) > shared default.
agmsg_team_storage_dir() {
  local team="$1" default_dir driver
  if [ -n "${AGMSG_STORAGE_PATH:-}" ]; then
    printf '%s\n' "${AGMSG_STORAGE_PATH%/}"
    return
  fi
  default_dir="$(agmsg_storage_dir)" || return 1
  driver="$(agmsg_team_storage_driver "$team")"
  if [ -n "$team" ] && [ -n "$driver" ]; then
    printf '%s\n' "$default_dir/teams/$team"
    return
  fi
  printf '%s\n' "$default_dir"
}

# Full path to <team>'s sqlite store (cygpath-converted like agmsg_db_path).
agmsg_team_db_path() {
  local db
  db="$(agmsg_team_storage_dir "$1")/messages.db" || return 1
  if command -v cygpath >/dev/null 2>&1; then
    db=$(cygpath -m "$db" 2>/dev/null || printf '%s' "$db")
  fi
  printf '%s\n' "$db"
}

# Escape a value as a SQL string literal (double every single quote). Shared by
# the storage drivers and any direct call site that interpolates into SQL.
agmsg_sqlesc() { printf %s "$1" | sed "s/'/''/g"; }

# Set <team>'s storage backend in its config (the "storage" key). This is the
# SINGLE writer of the team->driver mapping — the seam that 1.2 repoints to a
# DB write when teams/ moves into the (remote-capable) control store. Keep all
# driver-selection writes here. Mirrors join.sh's json_set config update.
agmsg_team_set_storage() {
  local team="$1" driver="$2" dir cfg updated
  dir="$(agmsg_teams_dir)/$team"; cfg="$dir/config.json"
  mkdir -p "$dir"
  if [ -f "$cfg" ]; then
    updated="$(agmsg_sqlite_mem "SELECT json_set(CAST(readfile('$(agmsg_sql_readfile_path "$cfg")') AS TEXT), '\$.storage', '$(agmsg_sqlesc "$driver")');")"
  else
    updated="$(agmsg_sqlite_mem "SELECT json_object('name','$(agmsg_sqlesc "$team")','storage','$(agmsg_sqlesc "$driver")');")"
  fi
  [ -n "$updated" ] || return 1
  printf '%s\n' "$updated" > "$cfg"
}

# --- Storage driver facade ---------------------------------------------------
# Load the active storage driver for <team> and bring its storage_* functions
# (storage_send / storage_list_unread / storage_mark_read / storage_history)
# into scope. The backend is the team's configured driver (teams/<team>/config
# "storage"), defaulting to the bundled "sqlite". Call this immediately before
# the storage_* calls for a given team; switching teams re-sources as needed
# (sourcing a driver file is idempotent). Drivers live under
# scripts/drivers/storage/<name>.sh and rely on the helpers above.
_AGMSG_LOADED_DRIVER=""
agmsg_storage_load() {
  local team="$1" name file kind base
  name="$(agmsg_team_storage_driver "$team")"
  [ -n "$name" ] && [ "$name" != "null" ] || name="sqlite"
  [ "$_AGMSG_LOADED_DRIVER" = "$name" ] && return 0
  # Discovery + trust reuse the axis-generic registry (ADR 0001/0002), the same
  # machinery the agent-type axis uses: built-ins under scripts/drivers/ always
  # load; external plugin dirs are gated by the opt-in trustfile. So a future
  # remote storage backend ships as a trusted external driver, no facade change.
  if ! command -v agmsg_driver_bases >/dev/null 2>&1; then
    # shellcheck disable=SC1090,SC1091
    . "$(agmsg_skill_dir)/scripts/lib/driver-registry.sh"
  fi
  while IFS="$(printf '\t')" read -r kind base; do
    [ -n "$base" ] || continue
    file="$base/storage/$name.sh"
    [ -f "$file" ] || continue
    if [ "$kind" = external ] && ! agmsg_driver_is_trusted storage "$name" "$file"; then
      continue
    fi
    # shellcheck disable=SC1090
    . "$file"
    _AGMSG_LOADED_DRIVER="$name"
    # Apply pending schema/data migrations for this store, once per (driver,team)
    # per process. Version-gated inside the driver, so this is a cheap no-op once
    # the store is current. Lazy migration means every store (global, per-team,
    # existing or future) is brought up to date on first use — no install-time
    # enumeration needed.
    local _mkey="$name/$team"
    case " ${_AGMSG_ENSURED:-} " in
      *" $_mkey "*) ;;
      *)
        if command -v storage_ensure_schema >/dev/null 2>&1; then
          storage_ensure_schema "$team" 2>/dev/null || true
        fi
        _AGMSG_ENSURED="${_AGMSG_ENSURED:-} $_mkey"
        ;;
    esac
    return 0
  done < <(agmsg_driver_bases)
  echo "agmsg: no trusted storage driver '$name' found" >&2
  return 1
}

# Run sqlite3 against the message store with a busy_timeout, so a writer that
# finds the DB locked WAITS for it instead of failing immediately with
# SQLITE_BUSY. WAL (set at init) lets readers and a single writer coexist, but
# concurrent writers still serialize; with the default busy_timeout=0 a leader
# fanning a job out to N members would lose all but one write — and silently,
# since the failed sends just exit non-zero. All DB-backed call sites go through
# this wrapper. In-memory JSON parsing (`sqlite3 :memory:`) does not need it —
# it has no file lock to contend for. Override the timeout via
# $AGMSG_BUSY_TIMEOUT (milliseconds). See #114.
#
# Uses the `.timeout` dot-command rather than `PRAGMA busy_timeout=N`: the
# PRAGMA returns its value as a row, which sqlite3 would print to stdout and
# corrupt every SELECT's output (and the watch stream). `.timeout` sets the
# same busy timeout silently.
# sqlite3 >= 3.50 renders control bytes in CLI output using caret notation —
# the char(31) record separator becomes the two literal chars "^_", and a CR
# becomes "^M". That breaks the `IFS=$'\x1f' read` field splitting in
# inbox/check-inbox/history and the monitor watch stream (#102), the same
# sqlite3 >= 3.50 escaping behaviour behind #143. `-escape off` restores the
# raw bytes. Older sqlite3 (< 3.50) doesn't know the option (and emits raw bytes
# anyway), so probe once and only pass the flag when the build accepts it.
_AGMSG_ESCAPE_FLAG=
_AGMSG_ESCAPE_PROBED=
_agmsg_escape_flag() {
  if [ -z "$_AGMSG_ESCAPE_PROBED" ]; then
    _AGMSG_ESCAPE_PROBED=1
    if sqlite3 -escape off :memory: "SELECT 1;" >/dev/null 2>&1; then
      _AGMSG_ESCAPE_FLAG="-escape off"
    fi
  fi
  printf '%s' "$_AGMSG_ESCAPE_FLAG"
}

agmsg_sqlite() {
  # shellcheck disable=SC2046  # intentional split: "-escape off" → two args, or none
  sqlite3 $(_agmsg_escape_flag) -cmd ".timeout ${AGMSG_BUSY_TIMEOUT:-5000}" "$@"
}

# In-memory sqlite for JSON parsing / scalar lookups whose stdout is captured in
# a command substitution ($(...)). On Windows, sqlite3.exe writes stdout in text
# mode and turns every \n into \r\n; command substitution strips the trailing \n
# but keeps the \r, so a captured "1" becomes "1\r" and string / integer
# comparisons silently fail — hooks don't get written, counts misparse, etc.
# (#130). Strip the CR; it is never a meaningful byte in a JSON or scalar result.
# No busy_timeout (a :memory: db has no file lock) and no escape flag (these
# call sites parse JSON/scalars, not the control-byte message stream).
agmsg_sqlite_mem() {
  sqlite3 :memory: "$@" | tr -d '\r'
}

# Turn a filesystem path into a form sqlite3's readfile() can open, then escape
# it as a SQL string literal. On Windows, sqlite3.exe is a native binary that
# can't open a Git Bash path like /d/a/agmsg/x.json — readfile() returns NULL
# and the surrounding json parse silently yields no rows. cygpath -w converts to
# the native D:\a\agmsg\x.json form first. No-op off Windows (cygpath absent).
# Mirrors delivery.sh's sql_readfile_path for the registry readfile() sites.
agmsg_sql_readfile_path() {
  local path="$1"
  if command -v cygpath >/dev/null 2>&1; then
    path=$(cygpath -w "$path" 2>/dev/null || printf '%s' "$path")
  fi
  printf '%s' "$path" | sed "s/'/''/g"
}
