import type {
  CommandRunInput,
  FsEntry,
  On,
  PromptSubmitInput,
  SessionCompactInput,
  SessionMeasureInput,
  SessionMessage,
  SessionReceiveInput,
  SessionStartInput,
  ToolCallInput,
  TurnCompleteInput,
} from 'claude-code'
import { mock } from 'claude-code/testing'

export type File = { text: string; mtimeMs: number }

export const README = '/work/.remember/demo/README.md'
export const MARKER = '/work/.remember/demo/.handoff'
export const TOOL = 'mcp__orch__handoff_done'
export const SESSION_ID = 'session-orchestrator'
export const START = 1_000_000
export const OLD = START - 60 * 60 * 1000

export const FRONTMATTER = `---
goal: Move the API and the CLI from Python to Go
linear_project: "Dev Health Ops"
canonical:
  - Linear document "Go cutover TRD" is the plan of record
  - 'ops/AGENTS.md for the backend rules'
role: |
  Keep the merge train moving.
  One lane for each PR.
---
# Demo project: single entry point

last updated 2026-10-01
`

export const SESSION: SessionStartInput = { surface: 'terminal', isInteractive: true, cwd: '/work' }

export const HEADLESS: SessionStartInput = { surface: null, isInteractive: false, cwd: '/work' }

export const orch = (args: string): CommandRunInput => ({
  command: 'orch',
  args,
  origin: { kind: 'composer' },
  presentation: { isFullscreen: true, columns: 160 },
})

export const typed = (text: string): PromptSubmitInput => ({
  text,
  wait: false,
  origin: { kind: 'composer' },
})

export const measureAt = (percent: number, tokens = percent * 10): SessionMeasureInput => ({
  context: { window: 1000, tokens, percent },
  rateLimits: [],
  changed: ['context'],
})

export const turnEnd = (turnId: string, more: Partial<TurnCompleteInput> = {}): TurnCompleteInput =>
  ({ answer: 'done', durationMs: 1, isAborted: false, turnId, reason: 'answer', ...more }) as TurnCompleteInput

export const compaction = (more: Partial<SessionCompactInput>): SessionCompactInput => ({
  trigger: 'manual',
  messages: [{ role: 'user', text: 'the conversation', toolUses: [] }],
  ...more,
})

/**
 * The world beneath the mod: files in memory, a clock the test moves, and a
 * record of what the mod showed, submitted, compacted and appended.
 */
export function worldOf(on: On, files: Record<string, File>, percent = 10) {
  const clock = mock.clock(on, { now: START })

  const seen = {
    status: [] as (string | undefined)[],
    toasts: [] as string[],
    logs: [] as string[],
    prompts: [] as string[],
    /** The context each prompt a plugin submitted entered with, beside `prompts`. */
    promptContext: [] as (readonly string[])[],
    typed: [] as string[],
    typedContext: [] as string[],
    compacts: [] as SessionCompactInput[],
    commands: [] as string[],
    writes: [] as string[],
    /** How many times a file was looked at. */
    stats: 0,
    /** The paths that were read, in order. */
    reads: [] as string[],
    /** The tools the mod registered, by full name. */
    tools: [] as string[],
    /** The messages the mod sent to another session. */
    sent: [] as { to: string; text: string }[],
  }

  const world = {
    clock,
    seen,
    files,
    /** Set: each write is refused for this reason. */
    writeError: '',
    /** Set: a prompt a plugin submits does not enter, for this reason. */
    dropPrompt: '',
    /** Set: each stat of a file takes this long on the test clock. */
    statMs: 0,
    /** Set: each read of a file takes this long on the test clock. */
    readMs: 0,
    /** The mod's `$.store`, as every session of the machine reads it. */
    store: {} as Record<string, unknown>,
    /** Set: a message to another session is not delivered, for this reason. */
    sendError: '',
    /** Set: the /compact command waits this long in the queue before it runs. */
    queueMs: 0,
    /** Set: the /compact command fails for this reason. */
    commandError: '',
    /** Set: the engine answers each compaction with a skip for this reason. */
    skipCompact: '',
    /** Set: each compaction takes this long on the test clock. */
    compactMs: 0,
    /** What the engine does when the /compact command runs: set by the test; nothing while unset. */
    runCompact: undefined as undefined | ((args: string) => Promise<unknown>),
    /** The main conversation's rows: each prompt that enters adds one, a compaction leaves its summary. */
    messages: [] as SessionMessage[],
  }

  const dirsUnder = (path: string): FsEntry[] => {
    const names = Object.keys(files)
      .filter(file => file.startsWith(`${path}/`))
      .map(file => file.slice(path.length + 1).split('/'))
      .filter(parts => parts.length > 1)
      .map(parts => parts[0] ?? '')

    return [...new Set(names)].map(name => ({ name, kind: 'dir', size: 0, mtimeMs: 0, isLink: false }))
  }

  on('session.start', (_engine, e) => ({ cwd: e.cwd }))
  on('session.cwd', () => ({ value: '/work' }))
  on('session.usage', () => ({
    value: { startedAt: 0, context: { window: 1000, tokens: percent * 10, percent }, rateLimits: [] },
  }))
  on('command.register', (_engine, e) => ({ value: { command: e.name } }))
  on('fs.exists', (_engine, e) => ({
    value: e.path in files || Object.keys(files).some(file => file.startsWith(`${e.path}/`)),
  }))
  on('fs.write', (_engine, e) => {
    if (world.writeError !== '') {
      return { deny: world.writeError }
    }

    seen.writes.push(e.path)
    files[e.path] = { text: e.text, mtimeMs: clock.now() }

    return { value: undefined }
  })
  on('fs.read', async (_engine, e) => {
    seen.reads.push(e.path)

    if (world.readMs > 0) {
      await clock.sleep(world.readMs)
    }

    const file = files[e.path]

    return file ? { value: file.text } : { deny: `no file at ${e.path}` }
  })
  on('fs.stat', async (_engine, e) => {
    seen.stats += 1

    if (world.statMs > 0) {
      await clock.sleep(world.statMs)
    }

    const file = files[e.path]

    return file
      ? { value: { kind: 'file', size: file.text.length, mtimeMs: file.mtimeMs, isLink: false } }
      : { deny: `no file at ${e.path}` }
  })
  on('fs.list', (_engine, e) => ({ value: dirsUnder(e.path) }))
  on('store.get', (_engine, e) => ({ value: world.store[e.key] }))
  on('store.set', (_engine, e) => {
    world.store[e.key] = JSON.parse(JSON.stringify(e.value))

    return { value: undefined }
  })
  on('store.delete', (_engine, e) => {
    delete world.store[e.key]

    return { value: undefined }
  })
  on('store.keys', () => ({ value: Object.keys(world.store) }))
  on('session.id', () => ({ value: SESSION_ID }))
  on('session.send', (_engine, e) => {
    seen.sent.push({ to: e.to, text: e.text })

    return world.sendError === '' ? { isDelivered: true } : { isDelivered: false, reason: world.sendError }
  })
  on('session.receive', (_engine, e) => ({ text: e.text }))
  on('tool.describe', (_engine, e) => ({ description: e.description }))
  on('tool.register', (_engine, e) => {
    seen.tools.push(`mcp__orch__${e.name}`)

    return { value: { tool: `mcp__orch__${e.name}` } }
  })
  on('ui.status', (_engine, e) => {
    seen.status.push(e.text)

    return { value: undefined }
  })
  on('ui.toast', (_engine, e) => {
    seen.toasts.push(e.text)

    return { value: undefined }
  })
  on('ui.log', (_engine, e) => {
    seen.logs.push(e.text)

    return { value: undefined }
  })
  on('prompt.submit', (_engine, e) => {
    if (e.origin.kind === 'plugin' && world.dropPrompt !== '') {
      return { drop: world.dropPrompt }
    }

    if (e.origin.kind === 'plugin') {
      seen.prompts.push(e.text)
      seen.promptContext.push(e.context ?? [])
    } else {
      seen.typed.push(e.text)
      seen.typedContext.push(...(e.context ?? []))
    }

    world.messages.push({ role: 'user', text: [e.text, ...(e.context ?? [])].join('\n\n'), toolUses: [] })

    return { text: e.text, context: e.context }
  })
  on('session.messages', () => ({ value: world.messages }))
  on('session.measure', (_engine, e) => ({ changed: e.changed }))
  on('session.compact', async (_engine, e) => {
    seen.compacts.push(e)

    if (world.compactMs > 0) {
      await clock.sleep(world.compactMs)
    }

    if (world.skipCompact !== '') {
      return { skip: world.skipCompact }
    }

    if (e.trigger !== 'precompute') {
      world.messages = [{ role: 'user', text: 'the summary', toolUses: [] }]
    }

    return {
      messages: [{ role: 'user', text: 'the summary', toolUses: [] }],
      tokensBefore: 900,
      tokensAfter: 100,
    }
  })
  on('command.run', { command: 'compact' }, async (_engine, e) => {
    seen.commands.push(e.args)

    if (world.queueMs > 0) {
      await clock.sleep(world.queueMs)
    }

    if (world.commandError !== '') {
      throw new Error(world.commandError)
    }

    await world.runCompact?.(e.args)

    return {}
  })
  on('turn.start', (_engine, e) => ({ turnId: e.turnId }))
  on('turn.complete', (_engine, e) => ({ text: e.answer }))

  return world
}

/** A `handoff_done` call as the query loop raises it; `agentId` for a subagent's or a teammate's loop. */
export const done = (slug: string, code: string, more: { agentId?: string; note?: string } = {}) =>
  ({ tool: TOOL, tool_use_id: 'toolu_1', slug, code, ...more }) as unknown as ToolCallInput

/** The delivery a `handoff_done` call in another session sends, as the engine frames it. */
export const relayed = (slug: string, code: string): SessionReceiveInput => ({
  origin: { kind: 'peer', plugin: 'orch' },
  text: `<cross-session-message from="uds:/tmp/cc-socks/1.sock" from-name="lane-x" from-mode="prompting">\n[orch-handoff-done] slug=${slug} code=${code}\n</cross-session-message>`,
})
