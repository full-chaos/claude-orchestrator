export type OrchBinding = {
  slug: string
  /** Absolute path of the README. */
  readme: string
  /** The README path as prompts name it, relative to the session directory. */
  readmeRel: string
  /** The handoff root as configured (`.remember`). */
  root: string
  goal: string
  linearProject: string
  canonical: string[]
  role: string
  hasFrontmatter: boolean
  lines: number
}

export type OrchPhase = 'idle' | 'requested' | 'running' | 'waiting' | 'compacting'

/**
 * One handoff sequence: `requested` (the prompt is submitted), `running` (the
 * handoff turn), `waiting` (the turn ended, no signal yet), `compacting` (the
 * signal came and /compact is asked for, or about to be), then `idle`.
 *
 * The signal is the `handoff_done` tool called with the open code, the same
 * code in the marker file, or the person's `/orch done`. No file time counts.
 */
export type OrchSequence = {
  phase: OrchPhase
  /** When the handoff was requested, milliseconds since the epoch. */
  startedAt: number
  /** The id of the handoff turn, once it started. */
  turnId: string
  /** When the phase began. */
  phaseAt: number
  /** When /compact was asked for; 0 while it was not. */
  askedAt: number
  /** How the last sequence ended; empty when none did. */
  lastEnd: string
  lastEndAt: number
  /** False after one sequence, until the fill drops below the warning level. */
  isArmed: boolean
  hasWarned: boolean
  hasNagged: boolean
  /** The one-time code of the open sequence; empty while none is open. */
  code: string
  /** The last code that was taken as a signal: a second call with it reads "used". */
  usedCode: string
  /** How the signal of the open sequence came (tool, relay, marker file, the person); empty before it. */
  signal: string
}

/** What `$.store` holds under `open/<slug>` while a sequence waits for its signal. */
export type OrchOpenRecord = {
  code: string
  /** The orchestrator session, as its `$.session.id()` answers. */
  sessionId: string
  at: number
}

/** What a `handoff_done` call in another session leaves under `done/<slug>`. */
export type OrchDoneRecord = {
  code: string
  at: number
  note: string
  /** The session that made the call. */
  from: string
}

declare module 'claude-code' {
  interface PluginState {
    orch: { binding: OrchBinding | null; sequence: OrchSequence }
  }
}
