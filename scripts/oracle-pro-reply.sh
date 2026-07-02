#!/usr/bin/env bash
set -euo pipefail

# Bridge unread agmsg messages for a codex-pro-* identity to Oracle's
# ChatGPT Pro browser route, then reply with the Oracle result.

usage() {
  cat >&2 <<'EOF'
Usage: oracle-pro-reply.sh <team> <agent> [--dry-run] [--file <path>]...

Environment:
  ORACLE_PRO_DRY_RUN=1       Preview the resolved Oracle browser run.
  ORACLE_PRO_ENGINE=browser  Oracle engine, defaults to ChatGPT browser mode.
  ORACLE_PRO_MODEL=gpt-5.5-pro
  ORACLE_PRO_FILES="a b"     Extra context files, space-separated.
EOF
}

TEAM="${1:-}"
AGENT="${2:-}"
if [ -z "$TEAM" ] || [ -z "$AGENT" ]; then
  usage
  exit 2
fi
shift 2

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DRY_RUN="${ORACLE_PRO_DRY_RUN:-0}"
FILES=()

while [ "$#" -gt 0 ]; do
  case "$1" in
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    --file)
      FILES+=("${2:?--file needs a path}")
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "oracle-pro-reply.sh: unknown argument: $1" >&2
      usage
      exit 2
      ;;
  esac
done

if [[ "$AGENT" != codex-pro-* ]]; then
  echo "oracle-pro-reply.sh: refusing non codex-pro-* agent: $AGENT" >&2
  exit 2
fi

if [ "${#FILES[@]}" -eq 0 ] && [ -n "${ORACLE_PRO_FILES:-}" ]; then
  # shellcheck disable=SC2206
  FILES=($ORACLE_PRO_FILES)
fi

nearest_doc() {
  local dir="$PWD"
  while [ "$dir" != "/" ]; do
    if [ -f "$dir/AGENTS.md" ]; then
      printf '%s\n' "$dir/AGENTS.md"
      return 0
    fi
    dir="$(dirname "$dir")"
  done
  if [ -f "$HOME/.codex/AGENTS.md" ]; then
    printf '%s\n' "$HOME/.codex/AGENTS.md"
    return 0
  fi
  return 1
}

if [ "${#FILES[@]}" -eq 0 ]; then
  if doc="$(nearest_doc)"; then
    FILES+=("$doc")
  fi
fi

if [ "${#FILES[@]}" -eq 0 ]; then
  echo "oracle-pro-reply.sh: no context file found; pass --file or ORACLE_PRO_FILES" >&2
  exit 2
fi

if command -v oracle >/dev/null 2>&1; then
  ORACLE_CMD=(oracle)
else
  ORACLE_CMD=(npx -y @steipete/oracle)
fi

INBOX_OUTPUT="$(bash "$SCRIPT_DIR/inbox.sh" "$TEAM" "$AGENT")"
printf '%s\n' "$INBOX_OUTPUT"

case "$INBOX_OUTPUT" in
  "No new messages."*|"No messages "*)
    exit 0
    ;;
esac

while IFS= read -r line; do
  if [[ "$line" =~ ^[[:space:]]*\[([^]]+)\][[:space:]]+([^:]+):[[:space:]](.*)$ ]]; then
    TS="${BASH_REMATCH[1]}"
    FROM="${BASH_REMATCH[2]}"
    BODY="${BASH_REMATCH[3]}"
    BODY="${BODY//\\n/$'\n'}"
    BODY="${BODY//\\t/$'\t'}"

    SLUG="agmsg-${AGENT#codex-pro-}-$(date +%Y%m%d-%H%M%S)"
    OUT="$(mktemp "${TMPDIR:-/tmp}/oracle-pro.XXXXXX.md")"
    PROMPT="$(cat <<EOF
You are GPT-5.5 Pro being consulted through Oracle from agmsg.

Requester: $FROM
Target agmsg identity: $AGENT
Received at: $TS

Answer the requester directly.
If the request asks for code changes, produce a precise review, plan, patch guidance, or risk assessment, but do not claim that you edited the local repository.
If the request touches production, payments, customer data, secrets, live trading, deploys, or external writes, call out the approval boundary explicitly.

Message:
$BODY
EOF
)"

    ARGS=(
      --engine "${ORACLE_PRO_ENGINE:-browser}"
      --model "${ORACLE_PRO_MODEL:-gpt-5.5-pro}"
      --prompt "$PROMPT"
      --slug "$SLUG"
      --timeout "${ORACLE_PRO_TIMEOUT:-auto}"
      --write-output "$OUT"
    )
    for f in "${FILES[@]}"; do
      ARGS+=(--file "$f")
    done
    if [ "$DRY_RUN" = "1" ]; then
      ARGS+=(--dry-run json)
    else
      ARGS+=(--wait)
    fi

    set +e
    RESULT="$("${ORACLE_CMD[@]}" "${ARGS[@]}" 2>&1)"
    STATUS=$?
    set -e

    if [ "$DRY_RUN" = "1" ]; then
      REPLY="Oracle GPT-5.5 Pro dry-run for message from $FROM:

$RESULT"
    elif [ "$STATUS" -eq 0 ] && [ -s "$OUT" ]; then
      REPLY="$(<"$OUT")"
    else
      REPLY="Oracle GPT-5.5 Pro route failed with exit $STATUS:

$RESULT"
    fi

    bash "$SCRIPT_DIR/send.sh" "$TEAM" "$AGENT" "$FROM" "$REPLY"
    rm -f "$OUT"
  fi
done <<< "$INBOX_OUTPUT"
