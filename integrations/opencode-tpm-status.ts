/**
 * tmux-project-manager status plugin for OpenCode
 *
 * Writes agent status into tmux session options so the tpm project picker
 * can surface which projects are waiting for input, working, done, etc.
 *
 * State model (see docs/agent-status.md for the full spec):
 *   needs-input   permission.asked                (highest priority)
 *   error         session.error
 *   done          session.idle
 *   working       session.status: busy
 *   ready         session.created (no parent)     (lowest priority)
 *
 * The plugin writes `@tpm-agent-status-opencode-<sessionID>` on the current
 * tmux session; the tpm scripts aggregate across all sources into the
 * `@tpm-agent-status` option that the picker reads.
 *
 * No-ops silently when:
 *   - not running inside tmux (TMUX env unset)
 *   - the tmux binary is not on PATH
 *   - the current tmux session is not managed by tpm
 *
 * Install:
 *   ln -sf /path/to/tmux-project-manager/integrations/opencode-tpm-status.ts \
 *          ~/.config/opencode/plugins/tpm-status.ts
 */

import { spawnSync } from "node:child_process"
import type { Plugin } from "@opencode-ai/plugin"

const SOURCE = "opencode"

type AgentState = "needs-input" | "error" | "done" | "working" | "ready"

// Resolve the tmux session name for the current process. Empty string when
// not inside tmux or when tmux is missing.
function currentTmuxSession(): string {
  if (!process.env.TMUX) return ""
  try {
    const r = spawnSync(
      "tmux",
      ["display-message", "-p", "#{session_name}"],
      { encoding: "utf8", stdio: ["ignore", "pipe", "ignore"] },
    )
    if (r.status !== 0) return ""
    return (r.stdout || "").trim()
  } catch {
    return ""
  }
}

function isTpmManaged(session: string): boolean {
  if (!session) return false
  try {
    const r = spawnSync(
      "tmux",
      ["show-option", "-t", `=${session}:`, "-qv", "@tpm-managed"],
      { encoding: "utf8", stdio: ["ignore", "pipe", "ignore"] },
    )
    return (r.stdout || "").trim() === "1"
  } catch {
    return false
  }
}

function writeStatus(session: string, sessionID: string, state: AgentState): void {
  const opt = `@tpm-agent-status-${SOURCE}-${sessionID}`
  spawnSync("tmux", ["set-option", "-t", `=${session}:`, opt, state], {
    stdio: "ignore",
  })
  // Recompute the aggregate. Best-effort — the script is bundled with tpm
  // and lives at a well-known relative path. If it's not present (user has
  // an older tpm version), the aggregate stays stale until next write; not
  // fatal.
  recomputeAggregate(session)
}

function clearStatus(session: string, sessionID: string): void {
  const opt = `@tpm-agent-status-${SOURCE}-${sessionID}`
  spawnSync("tmux", ["set-option", "-t", `=${session}:`, "-u", opt], {
    stdio: "ignore",
  })
  recomputeAggregate(session)
}

// Recompute the @tpm-agent-status aggregate for a session by shelling out
// to tpm's aggregator. We prefer the well-known TPM install path but fall
// back to `tpm-status` on PATH if the user has it symlinked.
function recomputeAggregate(session: string): void {
  const home = process.env.HOME || ""
  const candidates = [
    `${home}/.tmux/plugins/tmux-project-manager/scripts/recompute-status.sh`,
  ]
  for (const script of candidates) {
    const r = spawnSync("bash", [script, session], { stdio: "ignore" })
    if (r.status === 0 || r.status === 1) return  // 0 = ok; 1 = session gone
  }
  // If no script is available, do the aggregation inline as a fallback.
  // This keeps the plugin functional even if tpm scripts are missing.
  fallbackRecompute(session)
}

// Inline aggregate: read all @tpm-agent-status-* options, pick the highest
// priority, write it to @tpm-agent-status. Keep in sync with utils.sh's
// recompute_agent_status().
const PRIORITY: Record<string, number> = {
  "needs-input": 4,
  error: 3,
  done: 2,
  working: 1,
  ready: 0,
}
function fallbackRecompute(session: string): void {
  const list = spawnSync(
    "tmux",
    ["show-options", "-t", `=${session}:`],
    { encoding: "utf8", stdio: ["ignore", "pipe", "ignore"] },
  )
  if (list.status !== 0) return
  const lines = (list.stdout || "").split("\n")
  let bestState = ""
  let bestPrio = -1
  for (const line of lines) {
    if (!line.startsWith("@tpm-agent-status-")) continue
    const spaceIdx = line.indexOf(" ")
    if (spaceIdx < 0) continue
    let value = line.slice(spaceIdx + 1).trim()
    if (value.startsWith('"') && value.endsWith('"')) {
      value = value.slice(1, -1)
    }
    const prio = PRIORITY[value] ?? -1
    if (prio > bestPrio) {
      bestPrio = prio
      bestState = value
    }
  }
  if (bestState) {
    spawnSync(
      "tmux",
      ["set-option", "-t", `=${session}:`, "@tpm-agent-status", bestState],
      { stdio: "ignore" },
    )
  } else {
    spawnSync(
      "tmux",
      ["set-option", "-t", `=${session}:`, "-u", "@tpm-agent-status"],
      { stdio: "ignore" },
    )
  }
}

export const TpmStatusPlugin: Plugin = async () => {
  const tmuxSession = currentTmuxSession()
  if (!tmuxSession || !isTpmManaged(tmuxSession)) {
    // Not our problem. Return an empty plugin so opencode moves on.
    return {}
  }

  // Track subagents so we don't leak their status into the picker — the
  // user cares about the parent session's state.
  const subagentSessionIds = new Set<string>()
  const isSubagent = (sid: string | undefined) => !!sid && subagentSessionIds.has(sid)

  // Track which opencode session IDs we've written status for, so we can
  // clean them up when the process exits.
  const writtenIds = new Set<string>()

  function set(sessionID: string, state: AgentState): void {
    writeStatus(tmuxSession, sessionID, state)
    writtenIds.add(sessionID)
  }

  function clear(sessionID: string): void {
    clearStatus(tmuxSession, sessionID)
    writtenIds.delete(sessionID)
  }

  // Best-effort cleanup on process exit — otherwise a hard-killed opencode
  // leaves stale status behind. We only clear our own entries.
  process.on("exit", () => {
    for (const id of writtenIds) {
      spawnSync(
        "tmux",
        [
          "set-option",
          "-t",
          `=${tmuxSession}:`,
          "-u",
          `@tpm-agent-status-${SOURCE}-${id}`,
        ],
        { stdio: "ignore" },
      )
    }
  })

  return {
    event: async ({ event }) => {
      switch (event.type) {
        case "session.created": {
          const info = (event as any).properties?.info
          if (info?.parentID) {
            subagentSessionIds.add(info.id)
            break
          }
          if (info?.id) set(info.id, "ready")
          break
        }

        case "session.updated": {
          const info = (event as any).properties?.info
          if (info?.parentID) subagentSessionIds.add(info.id)
          break
        }

        case "session.deleted": {
          const info = (event as any).properties?.info
          if (info?.id) {
            subagentSessionIds.delete(info.id)
            clear(info.id)
          }
          break
        }

        case "session.status": {
          const props = (event as any).properties || {}
          const sid = props.sessionID
          if (isSubagent(sid) || !sid) break
          const status = props.status
          const statusType = typeof status === "object" ? (status as any)?.type : status
          if (statusType === "busy" || statusType === "running") {
            set(sid, "working")
          }
          break
        }

        case "session.idle": {
          const sid = (event as any).properties?.sessionID
          if (isSubagent(sid) || !sid) break
          set(sid, "done")
          break
        }

        case "session.error": {
          const sid = (event as any).properties?.sessionID
          if (isSubagent(sid) || !sid) break
          set(sid, "error")
          break
        }

        case "permission.asked": {
          // permission.asked doesn't always carry a sessionID; fall back to
          // a stable per-process id so we still contribute a status.
          const sid = (event as any).properties?.sessionID || `pid-${process.pid}`
          if (isSubagent(sid)) break
          set(sid, "needs-input")
          break
        }
      }
    },
  }
}

export default TpmStatusPlugin
