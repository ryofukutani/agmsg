---
name: agmsg
description: Cross-agent messaging via SQLite. Send messages between Claude Code, Codex, Gemini CLI, and other agents. No daemon, no network, no dependencies beyond bash and sqlite3.
---

Agent messaging command. **IMPORTANT: Always use the provided scripts. NEVER directly read or edit config files, DB, or team data. There is NO register.sh — use join.sh to join a team.**

## Identity

If you already know your AGENT and TEAMS from a previous `$agmsg` call in this session, skip to **Execute** below.

Otherwise, run: `~/.agents/skills/agmsg/scripts/whoami.sh "$(pwd)" codex`

Four possible outputs:

**A) Single identity:**
`agent=<name> teams=<t1,t2,...> type=codex project=<path>`
→ Remember AGENT and TEAMS, then go to **Execute**.

**B) Multiple identities:**
`multiple=true agents=<n1,n2,...> teams=<t1,t2,...> type=codex project=<path>`
→ Ask the user which agent name to use for this session, then go to **Execute**.

**C) Not in a team:**
`not_joined=true available_teams=<t1,t2,...>` (or `available_teams=none`)
→ Show the user the available teams from the output, then:

  > **First-time setup required.**
  > Joining a team so this agent can send and receive messages.
  > - **Team name**: a group of agents that can message each other (available: <list from output>)
  > - **Agent name**: this agent's identity within the team

  1. Ask: "Enter a team name (joins existing or creates new)"
  2. Ask: "Enter a name for this agent"
  3. **You MUST use join.sh** — run: `~/.agents/skills/agmsg/scripts/join.sh <team> <agent_name> codex "$(pwd)"`
  4. Show the result and explain:

  > **Joined!** You can now use `$agmsg` to check and send messages.
  > - `$agmsg` — check inbox
  > - `$agmsg send <agent> <message>` — send a message
  > - `$agmsg team` — list team members
  > - `$agmsg history` — message history

  5. **REQUIRED — Do NOT skip this step.** Ask the user to pick a delivery mode using exactly this prompt:

     ```
     Choose delivery mode for incoming messages:

       1) turn    — Check inbox at the end of each assistant turn
                    Stop hook pulls after each response. Recommended for Codex.

       2) off     — No automatic delivery
                    Manual $agmsg only.

      3) monitor — Real-time push (BETA, advanced)
                   Normal Codex.app sessions are woken with `codex exec resume`.
                   CLI shim sessions use the app-server bridge. See
                   docs/codex-monitor-beta.md.

     [1]:
     ```

     - **Wait for the user's answer before proceeding.** Empty input means `1` (turn).
     - Map the chosen number to a mode (`1`→`turn`, `2`→`off`, `3`→`monitor`) and run:
       `~/.agents/skills/agmsg/scripts/delivery.sh set <mode> codex "$(pwd)"`
     - If monitor is chosen, tell the user: "Codex monitor is a BETA. In Codex.app, `$agmsg actas <name>` starts a per-thread app monitor and incoming agmsg messages wake the same Codex.app thread through `codex exec resume`. CLI sessions can still use the optional `codex` shim/app-server bridge; if the output says `~/.agents/bin` is not on PATH, add `export PATH=\"$HOME/.agents/bin:$PATH\"` to your shell profile before relying on the CLI shim. For more info: https://github.com/fujibee/agmsg/blob/main/docs/codex-monitor-beta.md"

  6. Then check inbox for the newly joined team.

**D) Suggestions for reuse:**
`suggest=true agents=<n1,n2,...> teams=<t1,t2,...> type=codex project=<path> available_teams=<t1,t2,...>`
→ No exact registration exists for this project, but there are same-type agent names registered elsewhere.

  1. Show the suggested agent names to the user.
  2. Ask whether to reuse one of those names or choose a new one.
  3. Ask for the team name to join (existing or new).
  4. Run: `~/.agents/skills/agmsg/scripts/join.sh <team> <agent_name> codex "$(pwd)"`
  5. Then continue with the normal post-join flow above.

## Execute

**Only use scripts in `~/.agents/skills/agmsg/scripts/` — do not read or modify files under `teams/` or `db/` directly.**

**If no arguments provided (DEFAULT action — always do this when the command is invoked without arguments):**
1. **IMMEDIATELY** run inbox check for each TEAM: `~/.agents/skills/agmsg/scripts/inbox.sh $TEAM $AGENT`
2. If the active AGENT name starts with `codex-pro-`, route unread messages through Oracle GPT-5.5 Pro by running `~/.agents/skills/agmsg/scripts/oracle-pro-reply.sh $TEAM $AGENT` instead of answering them directly. Use `ORACLE_PRO_DRY_RUN=1` only when the user asks to preview the browser run.
3. Do NOT ask the user what to do — just run the inbox check.
4. If there are messages for a normal agent, read and respond appropriately. To reply:
   `~/.agents/skills/agmsg/scripts/send.sh $TEAM $AGENT <to_agent> "<message>"`

If argument is "history":
1. Run: `~/.agents/skills/agmsg/scripts/history.sh $TEAM $AGENT`

If argument is "team":
1. For each TEAM, run: `~/.agents/skills/agmsg/scripts/team.sh $TEAM`

If argument starts with "send" (e.g. "send misaki check the server"):
1. Parse target agent and message from the arguments
2. Determine which team the target agent belongs to, then run:
   `~/.agents/skills/agmsg/scripts/send.sh $TEAM $AGENT <to_agent> "<message>"`

If argument is "config":
1. Run: `~/.agents/skills/agmsg/scripts/config.sh show`
2. Show the output to the user.

If argument starts with "config set" (e.g. "config set hook.check_interval 30"):
1. Parse key and value from the arguments.
2. Run: `~/.agents/skills/agmsg/scripts/config.sh set <key> <value>`


If argument starts with "actas" followed by an agent name (e.g. "actas alice"):
1. Parse the new role name.
2. Run `~/.agents/skills/agmsg/scripts/identities.sh "$(pwd)" codex` to see whether the role is already registered for this (project, type).
3. If the name does not appear in the output, join under the existing team. For a single team, run `~/.agents/skills/agmsg/scripts/join.sh <team> <name> codex "$(pwd)"`. For multiple teams, ask the user which team to join the new role into.
4. Run `~/.agents/skills/agmsg/scripts/drivers/types/codex/actas-monitor.sh "$(pwd)" codex <name> "${CODEX_THREAD_ID:-}"`. This starts or rebinds receive-side monitor delivery for `<name>`. In ordinary Codex.app sessions it starts `codex-app-monitor.sh` for the current thread; in shim/app-server sessions it starts `codex-bridge.js`.
5. Set the session's active FROM to `<name>` for every `send.sh` call until another `actas`.
6. If `<name>` starts with `codex-pro-`, tell the user: "Now acting as `<name>`. This role is an Oracle GPT-5.5 Pro consult route; run `$agmsg` to process its unread inbox through `oracle-pro-reply.sh`. Real runs may control the signed-in ChatGPT browser."
7. Otherwise tell the user: "Now acting as `<name>`. Sends and monitor receive are bound to `<name>`."

If argument starts with "drop" followed by an agent name (e.g. "drop alice"):
1. Parse the role name.
2. Run `~/.agents/skills/agmsg/scripts/reset.sh "$(pwd)" codex <name>` to remove that role's registration.
3. If the session's active FROM was `<name>`, clear that state.
4. Tell the user: "Dropped role `<name>` from this project."

If argument starts with "spawn" (e.g. "spawn claude-code alice", "spawn codex reviewer --window"):
1. Parse `<type>` (must be `claude-code` or `codex`), `<name>`, and any options (`--project`, `--team`, `--window`, `--split h|v`, `--terminal`, `--no-wait`, `--ready-timeout <secs>`).
2. Run: `~/.agents/skills/agmsg/scripts/spawn.sh <type> <name> --project "$(pwd)" [options]`
   - spawn.sh pre-joins `<name>`, then opens a tmux pane/window (when this session is inside tmux) or a new OS terminal, and launches the target CLI with `/agmsg actas <name>` as its initial prompt.
   - By default it BLOCKS until a spawned claude-code agent's watcher attaches (`status=ready`); `status=timeout` + exit 3 if not ready within `--ready-timeout` (default 90s). `--no-wait` for fire-and-forget. Spawning a codex agent skips the wait (codex has no Monitor).
   - `--boot-prompt <text>`: hand the new agent an initial task — the boot prompt becomes the actas command followed (newline-separated) by <text>, so it claims its identity AND starts the task in its first turn. The only way to give a one-shot goal to a codex peer (no Monitor → a post-spawn send to its idle session is never noticed).
   - It refuses early if `<name>` is already held by another live session, if the target CLI is not installed, or if there is no tmux and no usable terminal (headless).
3. Show the script's output.

If argument starts with "despawn" (e.g. "despawn reviewer", "despawn alice --force"):
1. Parse `<name>` and any options (`--force`, `--timeout <secs>`). `despawn` is the inverse of `spawn` — it tears down a member you previously spawned.
2. Determine which team `<name>` belongs to (as with `send`), then run:
   `~/.agents/skills/agmsg/scripts/despawn.sh <team> $AGENT <name> [--force] [--timeout <secs>]`
   - Default (graceful): sends a `ctrl:despawn` control message to `<name>`. A claude-code member's watcher drops its own role and closes its own tmux pane, ending the agent. Blocks until the lock releases, up to `--timeout` (default 30s), then prints `status=ok`. On timeout it prints `status=timeout` and exits 3 — retry with `--force`. A codex member has no watcher to respond, so use `--force` for it.
   - `--force`: skips the message and tears the member down from the placement recorded at spawn time — kills its tmux pane/window and drops its registration.
3. Show the script's output.

If argument is "mode" (no further args):
1. Run: `~/.agents/skills/agmsg/scripts/delivery.sh status codex "$(pwd)"`
2. Show the output to the user.

If argument starts with "mode" followed by a mode name (e.g. "mode monitor"):
1. Parse the mode. Codex supports `monitor` (beta bridge), `turn`, and `off` — reject `both` with: "Codex bridge beta supports `monitor`, `turn`, or `off`; `both` is not supported yet."
2. Run: `~/.agents/skills/agmsg/scripts/delivery.sh set <mode> codex "$(pwd)"`
3. If mode is `monitor`, tell the user: "Codex monitor beta is enabled. agmsg installs an optional `codex` shim automatically. If the output says `~/.agents/bin` is not on PATH, add `export PATH=\"$HOME/.agents/bin:$PATH\"` to your shell profile, restart the shell, then launch future sessions with normal `codex`. If shim installation was refused because `~/.agents/bin/codex` already exists, use `~/.agents/skills/agmsg/scripts/drivers/types/codex/codex-monitor.sh` or resolve that command conflict. The bridge starts on the **first turn** of a new Codex session (the SessionStart hook fires on your first message, not the moment Codex opens), so **restart your Codex session and send one message for monitor to take effect** — this already-running session stays unmonitored until it restarts. For more info: https://github.com/fujibee/agmsg/blob/main/docs/codex-monitor-beta.md"

If argument is "hook on" (legacy alias):
1. Run: `~/.agents/skills/agmsg/scripts/delivery.sh set turn codex "$(pwd)"`
2. Tell the user: "Delivery mode set to 'turn' (legacy hook on behavior)."

If argument is "hook off" (legacy alias):
1. Run: `~/.agents/skills/agmsg/scripts/delivery.sh set off codex "$(pwd)"`
2. Tell the user: "Delivery mode set to 'off'."

If argument is "version":
1. Run: `~/.agents/skills/agmsg/scripts/version.sh`
2. Show the output — the installed version (git-describe provenance recorded at install time).

If argument is "reset":
1. Run: `~/.agents/skills/agmsg/scripts/reset.sh "$(pwd)" codex`
2. Tell the user the result.
