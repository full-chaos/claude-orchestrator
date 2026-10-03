import { atom, read, update } from 'claude-code'
import type {
  EngineInterface,
  PluginOptions,
  Register,
  SessionCompactInput,
  SessionMeasureInput,
  Timer,
} from 'claude-code'

import type { OrchBinding, OrchDoneRecord, OrchOpenRecord, OrchPhase, OrchSequence } from '../types'
import { FRONTMATTER_KEYS, GOAL_TODO, isNewSlug, isSlug, parseProject, scaffoldOf, slugsIn } from './project'
import { fillRole } from './role'

const SECTION_ID = 'orch:role'
const HANDOFF_MARK = '[orch] Update the handoff now'
const OWN_MARK = 'The handoff file was updated before this compaction.'
const TOOL_NAME = 'handoff_done'
const TOOL = 'mcp__orch__handoff_done'
const TOOL_TEXT =
  'Signals to the orch mod that the handoff of an orchestrator project is written. Call it once, only after the handoff for that project is written to its files. `slug` and `code` are the ones the handoff request of the orch mod gives. The orchestrator session then compacts between turns.'
/** What a call in another session sends to the orchestrator's session; its `session.receive` hook takes it. */
const RELAY_MARK = '[orch-handoff-done]'
/** The backup signal: a file beside the README whose content holds the open code. */
const MARKER_FILE = '.handoff'
const SETTLE_MS = 500
/** How often an open sequence looks for the backup signals (the marker file, a relay record) with no turn end. */
const POLL_MS = 15 * 1000
const SLOW_TICK_MS = 60 * 1000
/** How long the handoff turn has to start and to end. */
const SEQUENCE_TIMEOUT_MS = 30 * 60 * 1000
/** How long /compact has to come to the front of the queue after it was asked for. */
const COMPACT_WAIT_MS = 30 * 60 * 1000
const STOP_TOAST_MS = 20 * 1000
const FRESH_WINDOW_MS = 10 * 60 * 1000
const CODE_LETTERS = 'abcdefghjkmnpqrstuvwxyz23456789'
const USAGE = 'usage: /orch <slug> | /orch new <slug> [goal] | /orch | /orch off | /orch handoff | /orch done'

type Mode = 'auto' | 'ask' | 'off'

type Config = {
  root: string
  limitPercent: number
  warnPercent: number
  limitTokens: number
  mode: Mode
  readmeMaxLines: number
  /** How long a sequence waits for its signal after the handoff turn. */
  waitMs: number
}

const IDLE: OrchSequence = {
  phase: 'idle',
  startedAt: 0,
  turnId: '',
  phaseAt: 0,
  askedAt: 0,
  lastEnd: '',
  lastEndAt: 0,
  isArmed: true,
  hasWarned: false,
  hasNagged: false,
  code: '',
  usedCode: '',
  signal: '',
}

const SEQUENCE = { plugin: 'orch', key: 'sequence' } as const

const binding = atom({ plugin: 'orch', key: 'binding' } as const, null)
const sequence = atom(SEQUENCE, IDLE)

let isInteractive = true
/** The sequence as this module last read or wrote it: `$.state` holds the same value for a reload. */
let held: OrchSequence | null = null
/** The binding as this module last read or wrote it; undefined before the first read of a load. */
let boundNow: OrchBinding | null | undefined
let tick: Timer | null = null
let tickMs = 0
let isStepping = false
/** The backup signals that were read and did not count, each logged once for a sequence. */
let ignored = new Set<string>()
/** How the /compact this module asked for ended, from the moment it ran until the sequence settles on it. */
let ownOutcome: { isDone: boolean; reason: string } | null = null

let config: Config = {
  root: '.remember',
  limitPercent: 55,
  warnPercent: 45,
  limitTokens: 0,
  mode: 'auto',
  readmeMaxLines: 300,
  waitMs: 10 * 60 * 1000,
}

function numberOf(value: unknown, fallback: number): number {
  return typeof value === 'number' && Number.isFinite(value) && value >= 0 ? value : fallback
}

function configOf(options: PluginOptions): Config {
  const root = typeof options.rememberRoot === 'string' ? options.rememberRoot : ''
  const mode = options.mode

  return {
    root: root.replace(/^\.\/|\/+$/g, '') || '.remember',
    limitPercent: numberOf(options.limitPercent, 55) || 55,
    warnPercent: numberOf(options.warnPercent, 45),
    limitTokens: numberOf(options.limitTokens, 0),
    mode: mode === 'ask' || mode === 'off' ? mode : 'auto',
    readmeMaxLines: numberOf(options.readmeMaxLines, 300),
    waitMs: (numberOf(options.handoffWaitMinutes, 10) || 10) * 60 * 1000,
  }
}

function messageOf(error: unknown): string {
  return error instanceof Error ? error.message : String(error)
}

function roleOf(b: OrchBinding): string {
  return fillRole({
    slug: b.slug,
    goal: b.goal,
    readme: b.readmeRel,
    dir: `${b.root}/${b.slug}`,
    root: b.root,
    linear_project: b.linearProject,
    canonical: b.canonical,
    limit: config.limitPercent,
    role: b.role,
  })
}

/**
 * The role as a message of the conversation. The engine renders the system
 * prompt at the first request and again after a compaction, so a session
 * bound between the two reads its role here until the next compaction.
 */
function roleMessageOf(b: OrchBinding): string {
  return `The orch mod bound this session to orchestrator project ${b.slug}. After the next compaction the system prompt holds the section below; until then this message is that section.\n\n${roleOf(b)}`
}

function markerOf(b: OrchBinding): string {
  return b.readme.replace(/README\.md$/, MARKER_FILE)
}

function markerRelOf(b: OrchBinding): string {
  return b.readmeRel.replace(/README\.md$/, MARKER_FILE)
}

function minutesOf(ms: number): string {
  return String(Math.round((ms / 60000) * 100) / 100)
}

function handoffPromptOf(b: OrchBinding, code: string): string {
  return [
    `${HANDOFF_MARK}: in ${b.readme} (and the state files it points to) write current state, open lanes, pending decisions, restart steps. Do not start new work.`,
    `When the handoff is written, call the tool ${TOOL} with slug "${b.slug}" and code "${code}". That call is the signal: the orch mod then compacts this session between turns. Nothing else starts the compaction.`,
    `If a scribe or a lane writes the handoff, give it the slug and the code: it makes the call itself after the write.`,
    `Where the tool is not available, write the code into the file ${markerOf(b)} (its content is the code).`,
    `Then stop. The wait for the signal ends ${minutesOf(config.waitMs)} minutes after this turn.`,
  ].join(' ')
}

function signalHelpOf(b: OrchBinding, code: string): string {
  return `signal: call ${TOOL} with slug "${b.slug}" and code "${code}", or write the code to ${markerRelOf(b)}, or run /orch done`
}

function newCode(): string {
  const letters = [...crypto.getRandomValues(new Uint8Array(8))].map(
    byte => CODE_LETTERS[byte % CODE_LETTERS.length] ?? 'x',
  )

  return `${letters.slice(0, 4).join('')}-${letters.slice(4).join('')}`
}

function openKeyOf(slug: string): string {
  return `open/${slug}`
}

function doneKeyOf(slug: string): string {
  return `done/${slug}`
}

function isOpenRecord(value: unknown): value is OrchOpenRecord {
  const record = value as Partial<OrchOpenRecord> | null | undefined

  return typeof record?.code === 'string' && typeof record.sessionId === 'string'
}

function isDoneRecord(value: unknown): value is OrchDoneRecord {
  const record = value as Partial<OrchDoneRecord> | null | undefined

  return typeof record?.code === 'string'
}

function restartPromptOf(b: OrchBinding): string {
  return `Read ${b.readme} and continue as orchestrator for ${b.slug}.`
}

function projectLineOf(b: OrchBinding): string {
  return `Orchestrator for ${b.slug}: ${b.goal}. Keep: open lanes, pending decisions, in-flight PRs and tickets, restart steps. Entry point ${b.readmeRel}.`
}

function describe(b: OrchBinding): string {
  const lines = [
    `bound to ${b.slug} (${b.readmeRel}, ${b.lines} lines)`,
    `goal: ${b.goal}`,
    `linear: ${b.linearProject === '' ? 'not set' : b.linearProject}`,
  ]

  if (b.canonical.length > 0) {
    lines.push(`canonical: ${b.canonical.join(' | ')}`)
  }

  lines.push(
    `handoff signal: the tool ${TOOL} with the code of the handoff request (backup: the code in ${markerRelOf(b)}, or /orch done). Compaction follows the signal.`,
  )

  if (!b.hasFrontmatter) {
    lines.push(
      `frontmatter missing: the goal is the first heading. Add these keys between two --- lines at the top of the README: ${FRONTMATTER_KEYS.join(', ')}.`,
    )
  }

  if (b.lines > config.readmeMaxLines) {
    lines.push(
      `warning: the README has ${b.lines} lines (limit ${config.readmeMaxLines}). It is the entry point: move state to the files it points to.`,
    )
  }

  return lines.join('\n')
}

function note($: EngineInterface, text: string): void {
  $.ui.log(text)
}

function showStatus($: EngineInterface, b: OrchBinding | null, percent: number | undefined): void {
  $.ui.status(
    b === null ? undefined : `${b.slug} ${percent === undefined ? '-' : percent}/${config.limitPercent}%`,
  )
}

async function percentNow($: EngineInterface): Promise<number | undefined> {
  try {
    return (await $.session.usage()).context.percent
  } catch (error) {
    note($, `the context fill is not available: ${messageOf(error)}`)

    return undefined
  }
}

async function bindingNow($: EngineInterface): Promise<OrchBinding | null> {
  if (boundNow === undefined) {
    const stored = await read($, binding)

    boundNow ??= stored
  }

  return boundNow
}

async function sequenceNow($: EngineInterface): Promise<OrchSequence> {
  if (held === null) {
    const stored = await read($, sequence)

    held ??= { ...IDLE, ...stored }
  }

  return held
}

async function patch($: EngineInterface, change: Partial<OrchSequence>): Promise<OrchSequence> {
  const next: OrchSequence = { ...(held ?? (await sequenceNow($))), ...change }

  held = next
  await $.state.set(SEQUENCE, next)

  return next
}

function isOpen(phase: OrchPhase): boolean {
  return phase !== 'idle'
}

function cancelTick(): void {
  tick?.cancel()
  tick = null
}

function tickMsOf(state: OrchSequence): number {
  if (state.phase === 'compacting') {
    // Signaled and not asked for yet (a load of the module came between): ask soon.
    return state.askedAt === 0 ? SETTLE_MS : SLOW_TICK_MS
  }

  return POLL_MS
}

/**
 * One timer while a sequence is open. A turn end drives the sequence in a busy
 * session; the timer drives it in a quiet one, and applies each time limit.
 */
function armTick($: EngineInterface, state: OrchSequence): void {
  if (!isOpen(state.phase)) {
    return
  }

  const ms = tickMsOf(state)

  if (tick !== null && tickMs <= ms) {
    return
  }

  cancelTick()
  tickMs = ms
  tick = $.clock.after(ms, () => {
    tick = null
    void step($)
  })
}

function agoOf(ms: number): string {
  const seconds = Math.max(0, Math.round(ms / 1000))

  return seconds < 120 ? `${seconds} s` : `${Math.round(seconds / 60)} min`
}

function describeSequence(state: OrchSequence, now: number, b: OrchBinding | null): string[] {
  const lines: string[] = []

  if (state.phase === 'idle') {
    lines.push(
      `sequence: idle${state.isArmed ? '' : ' (not armed: the fill did not drop below the warning level after the last sequence)'}`,
    )
  } else if (state.phase === 'requested') {
    lines.push(`sequence: handoff prompt sent ${agoOf(now - state.startedAt)} ago; its turn has not started`)
  } else if (state.phase === 'running') {
    lines.push(`sequence: the handoff turn is running (requested ${agoOf(now - state.startedAt)} ago)`)
  } else if (state.phase === 'waiting') {
    lines.push(
      `sequence: waiting for the handoff signal (${agoOf(now - state.phaseAt)} of ${minutesOf(config.waitMs)} min). Compaction follows the signal.`,
    )
  } else {
    lines.push(
      state.askedAt > 0
        ? `sequence: handoff signaled (${state.signal}); /compact is in the queue (asked ${agoOf(now - state.askedAt)} ago; it runs between turns, and the wait ends after ${COMPACT_WAIT_MS / 60000} min)`
        : `sequence: handoff signaled (${state.signal}); /compact is not asked for yet`,
    )
  }

  if (b !== null && state.phase !== 'idle' && state.phase !== 'compacting') {
    lines.push(`code: ${state.code}`, signalHelpOf(b, state.code))
  }

  if (state.lastEnd !== '') {
    lines.push(`last sequence: ${state.lastEnd} (${agoOf(now - state.lastEndAt)} ago)`)
  }

  return lines
}

async function slugsOf($: EngineInterface): Promise<string[]> {
  const root = `${await $.session.cwd()}/${config.root}`

  if (!(await $.fs.exists(root))) {
    return []
  }

  const entries = await $.fs.list(root)
  const slugs: string[] = []

  for (const entry of entries) {
    if (entry.kind === 'dir' && isSlug(entry.name) && (await $.fs.exists(`${root}/${entry.name}/README.md`))) {
      slugs.push(entry.name)
    }
  }

  return slugs.sort()
}

/** A bind or an unbind starts from an idle sequence; one that was open is stopped, and says so. */
async function dropSequence($: EngineInterface, why: string): Promise<void> {
  const state = await sequenceNow($)

  if (isOpen(state.phase)) {
    await stop($, `${why} in phase ${state.phase}`, 'No compaction.')
  }

  const { lastEnd, lastEndAt } = await sequenceNow($)

  await patch($, { ...IDLE, lastEnd, lastEndAt })
}

async function bind($: EngineInterface, slug: string): Promise<OrchBinding | string> {
  if (!isSlug(slug)) {
    return `"${slug}" is not a project name. ${USAGE}`
  }

  const readmeRel = `${config.root}/${slug}/README.md`
  const readme = `${await $.session.cwd()}/${readmeRel}`

  if (!(await $.fs.exists(readme))) {
    const hint = isNewSlug(slug) ? `: create it with /orch new ${slug}` : ''

    return `${readmeRel} does not exist${hint}. projects: ${(await slugsOf($)).join(', ') || 'none'}`
  }

  const project = parseProject(await $.fs.read(readme), slug)
  const bound: OrchBinding = { slug, readme, readmeRel, root: config.root, ...project }

  await dropSequence($, `bound to ${slug}`)
  boundNow = bound
  await update($, binding, () => bound)
  showStatus($, bound, await percentNow($))
  note($, `bound to ${slug} (${readmeRel})`)

  return bound
}

async function unbind($: EngineInterface): Promise<void> {
  await dropSequence($, 'unbound')
  boundNow = null
  await update($, binding, () => null)
  showStatus($, null, undefined)
  note($, 'unbound')
}

/**
 * Binds from the person's own words: one project README named, and the word
 * orchestrator beside it. Any other text binds nothing.
 */
async function autoBind($: EngineInterface, text: string): Promise<OrchBinding | null> {
  if (!/\borchestrat/i.test(text)) {
    return null
  }

  const slugs = slugsIn(text, config.root)
  const slug = slugs[0]

  if (slugs.length !== 1 || slug === undefined) {
    return null
  }

  const bound = await bind($, slug)

  if (typeof bound === 'string') {
    $.ui.log(bound, { to: 'debug' })

    return null
  }

  $.ui.toast(`bound to ${slug} from your prompt. /orch off unbinds.`)

  return bound
}

/** Removes what the open sequence left in `$.store` for the sessions of the lanes. */
async function withdraw($: EngineInterface, slug: string, keys: readonly string[]): Promise<void> {
  try {
    for (const key of keys) {
      await $.store.delete(key)
    }
  } catch (error) {
    note($, `the store records of ${slug} were not removed: ${messageOf(error)}`)
  }
}

/**
 * Ends the open sequence. With `endedAt` given, the phase is `idle` before the
 * first await: what comes next to end the same sequence finds none open.
 */
async function endSequence($: EngineInterface, reason: string, endedAt?: number): Promise<void> {
  cancelTick()

  const at = endedAt ?? (await $.clock.now())

  await patch($, {
    phase: 'idle',
    turnId: '',
    phaseAt: 0,
    askedAt: 0,
    code: '',
    signal: '',
    lastEnd: reason,
    lastEndAt: at,
  })
  note($, `sequence ended: ${reason}`)

  const slug = boundNow?.slug

  if (slug !== undefined) {
    await withdraw($, slug, [openKeyOf(slug), doneKeyOf(slug)])
  }
}

/** Ends a sequence that did not compact. The person reads why in a toast and in the log. */
async function stop($: EngineInterface, reason: string, advice: string, endedAt?: number): Promise<void> {
  await endSequence($, reason, endedAt)
  $.ui.toast(`handoff sequence stopped: ${reason}. ${advice}`, { timeoutMs: STOP_TOAST_MS })
}

async function submitHandoff($: EngineInterface): Promise<void> {
  try {
    const b = await bindingNow($)

    if (b === null) {
      await stop($, 'unbound before the handoff prompt', 'No compaction.')

      return
    }

    const entered = await $.prompt.submit({ text: handoffPromptOf(b, (await sequenceNow($)).code) })

    if (entered.drop !== undefined) {
      await stop($, `the handoff prompt did not enter: ${entered.drop}`, 'Run /orch handoff.')
    }
  } catch (error) {
    await stop($, `the handoff prompt failed: ${messageOf(error)}`, 'Run /orch handoff.')
  }
}

/**
 * Starts one handoff sequence unless one is in flight; the prompt is submitted
 * after the dispatch, as a prompt starts only once the session is idle.
 */
async function requestHandoff($: EngineInterface, why: string): Promise<boolean> {
  const startedAt = await $.clock.now()

  if (isOpen((await sequenceNow($)).phase)) {
    return false
  }

  const code = newCode()
  const state = await patch($, {
    phase: 'requested',
    startedAt,
    turnId: '',
    phaseAt: startedAt,
    askedAt: 0,
    isArmed: false,
    code,
    signal: '',
  })

  ignored = new Set()
  note($, `handoff requested (${why}); code ${code}`)

  const slug = boundNow?.slug

  if (slug !== undefined) {
    // What a handoff_done call in another session reads: the code, and where this session is.
    try {
      await $.store.delete(doneKeyOf(slug))
      const record: OrchOpenRecord = { code, sessionId: await $.session.id(), at: startedAt }

      await $.store.set(openKeyOf(slug), record)
    } catch (error) {
      note($, `the open record of ${slug} was not stored (a call in another session cannot find this one): ${messageOf(error)}`)
    }
  }

  $.clock.after(0, () => {
    void submitHandoff($)
  })
  armTick($, state)

  return true
}

/** A compaction stood: the sequence ends and the restart prompt goes in. */
async function complete($: EngineInterface, b: OrchBinding, how: string, endedAt: number): Promise<void> {
  await endSequence($, how, endedAt)

  // Not awaited: the prompt's own turn starts when the session is free.
  void $.prompt.submit({ text: restartPromptOf(b) }).then(
    entered => {
      if (entered.drop === undefined) {
        note($, 'restart prompt submitted')
      } else {
        note($, `restart prompt dropped: ${entered.drop}`)
        $.ui.toast(`compacted, but the restart prompt did not enter: ${entered.drop}`, { timeoutMs: STOP_TOAST_MS })
      }
    },
    (error: unknown) => {
      note($, `restart prompt failed: ${messageOf(error)}`)
      $.ui.toast(`compacted, but the restart prompt failed: ${messageOf(error)}`, { timeoutMs: STOP_TOAST_MS })
    },
  )
}

/**
 * The /compact this module asked for has run, or its call failed: the sequence
 * ends on how it went. The compaction hook and the command's own answer both
 * come here, and a module loaded after the request comes through the hook
 * alone; the first one to come settles, the next finds nothing to do.
 */
async function settle($: EngineInterface, fallback: string): Promise<void> {
  try {
    const at = await $.clock.now()
    const b = await bindingNow($)
    const state = held ?? (await sequenceNow($))

    if (state.phase !== 'compacting' || state.askedAt === 0) {
      return
    }

    const outcome = ownOutcome

    ownOutcome = null

    // No await from the check above to the end of the sequence: the second report finds it idle.
    if (outcome?.isDone === true && b !== null) {
      await complete($, b, `compacted (${outcome.reason})`, at)
    } else {
      await stop($, `no compaction: ${outcome?.reason ?? fallback}`, 'Run /compact.', at)
    }
  } catch (error) {
    note($, `the sequence did not settle: ${messageOf(error)}`)
  }
}

/**
 * Asks for the compaction with the /compact command.
 *
 * The engine queues the command behind the prompts that wait and runs it
 * between two turns, so a busy session compacts too. `$.session.compact` is
 * not used: live, with a prompt in the queue, the engine starts that prompt a
 * few milliseconds after a turn ends and then refuses the call ("a turn is in
 * flight"), at each turn end, for as long as the session stays busy.
 */
async function ask($: EngineInterface): Promise<void> {
  const at = await $.clock.now()
  const saved = patch($, { phase: 'compacting', phaseAt: at, askedAt: at })

  ownOutcome = null
  void $.command.run({ command: 'compact', args: OWN_MARK }).then(
    () => settle($, '/compact ran and did not compact'),
    (error: unknown) => settle($, `/compact failed: ${messageOf(error)}`),
  )
  await saved
  note($, 'handoff signaled; /compact asked for. It runs between turns, after the prompts that wait in the queue.')
}

type Verdict = 'ok' | 'used' | 'wrong' | 'closed'

/**
 * Takes one signal for the open sequence. The check and the change of phase
 * are one synchronous step, so two signals that come together count once.
 */
async function signal($: EngineInterface, code: string, how: string, detail: string): Promise<Verdict> {
  const state = held ?? (await sequenceNow($))

  if (state.phase === 'idle') {
    return code !== '' && code === state.usedCode ? 'used' : 'closed'
  }

  if (state.phase === 'compacting') {
    return code === state.usedCode ? 'used' : 'wrong'
  }

  if (code !== state.code) {
    return 'wrong'
  }

  // No await between the check above and this change of `held`.
  const saved = patch($, { phase: 'compacting', askedAt: 0, signal: how, usedCode: code })

  await saved
  await patch($, { phaseAt: await $.clock.now() })
  note($, `handoff signal received (${how})${detail === '' ? '' : `: ${detail}`}`)

  const slug = boundNow?.slug

  if (slug !== undefined) {
    // A later call in another session reads "no open sequence".
    await withdraw($, slug, [openKeyOf(slug)])
  }

  return 'ok'
}

function noteOnce($: EngineInterface, key: string, text: string): void {
  if (!ignored.has(key)) {
    ignored.add(key)
    note($, text)
  }
}

/**
 * The backup signals of an open sequence: the marker file beside the README,
 * and the record a `handoff_done` call in another session left in `$.store`.
 * Only the open code counts; a file time counts for nothing.
 */
async function backupOf($: EngineInterface, b: OrchBinding, state: OrchSequence): Promise<string | null> {
  try {
    const marker = markerOf(b)

    if (await $.fs.exists(marker)) {
      const text = (await $.fs.read(marker)).trim().toLowerCase()

      if (text.includes(state.code)) {
        return `marker file ${markerRelOf(b)}`
      }

      noteOnce(
        $,
        `marker:${text}`,
        `${markerRelOf(b)} ${text === '' ? 'is empty' : 'holds a wrong or an old code'}: ignored. The open code is ${state.code}.`,
      )
    }
  } catch (error) {
    noteOnce($, 'marker:error', `${markerRelOf(b)} could not be read: ${messageOf(error)}`)
  }

  try {
    const done = await $.store.get(doneKeyOf(b.slug))

    if (isDoneRecord(done)) {
      if (done.code === state.code) {
        return `relay record from session ${done.from}`
      }

      noteOnce($, `done:${done.code}`, `the relay record of ${b.slug} holds a wrong or an old code: ignored.`)
    }
  } catch (error) {
    noteOnce($, 'done:error', `the relay record of ${b.slug} could not be read: ${messageOf(error)}`)
  }

  return null
}

/**
 * Moves an open sequence one step: looks for a backup signal, applies the time
 * limits, and asks for the compaction once the signal is in.
 */
async function advance($: EngineInterface): Promise<void> {
  const state = await sequenceNow($)

  if (!isOpen(state.phase)) {
    return
  }

  const b = await bindingNow($)

  if (b === null) {
    await stop($, `the session is not bound (phase ${state.phase})`, 'No compaction.')

    return
  }

  if (state.phase === 'compacting') {
    if (state.askedAt === 0) {
      await ask($)
    } else if ((await $.clock.now()) - state.askedAt > COMPACT_WAIT_MS) {
      // The command is in the queue, asked for by this module or by the one a
      // reload replaced. It is never asked for twice.
      await stop(
        $,
        `no compaction: /compact did not run in ${COMPACT_WAIT_MS / 60000} minutes after it was asked for`,
        'Run /compact.',
      )
    }

    return
  }

  const how = await backupOf($, b, state)
  const now = await $.clock.now()

  // A signal that came while this step read the backups has moved the sequence on.
  if (held !== null && (held.phase !== state.phase || held.code !== state.code)) {
    return
  }

  if (how !== null) {
    if ((await signal($, state.code, how, '')) === 'ok') {
      await ask($)
    }

    return
  }

  if (state.phase === 'waiting') {
    if (now - state.phaseAt > config.waitMs) {
      await stop(
        $,
        `no handoff signal: ${TOOL_NAME} was not called with code ${state.code} in ${minutesOf(config.waitMs)} minutes after the handoff turn`,
        'No compaction. Run /orch handoff when the handoff is written.',
      )
    }

    return
  }

  if (now - state.startedAt > SEQUENCE_TIMEOUT_MS) {
    await stop(
      $,
      `timed out: the handoff turn did not ${state.phase === 'requested' ? 'start' : 'end'} in ${SEQUENCE_TIMEOUT_MS / 60000} minutes`,
      'Run /orch handoff.',
    )
  }
}

/** One step at a time; each call leaves the timer armed while the sequence is open. */
async function step($: EngineInterface): Promise<void> {
  if (!isStepping) {
    isStepping = true

    try {
      await advance($)
    } catch (error) {
      await stop($, `failed: ${messageOf(error)}`, 'Run /orch handoff.').catch((later: unknown) => {
        note($, `the sequence state did not reset: ${messageOf(later)}`)
      })
    } finally {
      isStepping = false
    }
  }

  // A sequence that took its signal while a step ran is asked for on the short timer this arms.

  try {
    armTick($, await sequenceNow($))
  } catch (error) {
    note($, `the sequence timer did not start: ${messageOf(error)}`)
  }
}

/** A step after the dispatch that took a signal: /compact cannot be asked for inside a hook a turn waits on. */
function stepSoon($: EngineInterface): void {
  $.clock.after(0, () => {
    void step($)
  })
}

function fillOf(percent: number, tokens: number | undefined): number {
  const byPercent = percent / config.limitPercent
  const byTokens = config.limitTokens > 0 && tokens !== undefined ? tokens / config.limitTokens : 0

  return Math.max(byPercent, byTokens)
}

async function onMeasure($: EngineInterface, e: SessionMeasureInput): Promise<void> {
  const b = await bindingNow($)

  if (b === null) {
    return
  }

  const percent = e.context.percent

  showStatus($, b, percent)

  if (percent === undefined || config.mode === 'off') {
    return
  }

  const state = await sequenceNow($)

  if (isOpen(state.phase)) {
    armTick($, state)

    return
  }

  const fill = fillOf(percent, e.context.tokens)

  if (fill < config.warnPercent / config.limitPercent) {
    if (!state.isArmed || state.hasWarned || state.hasNagged) {
      await patch($, { isArmed: true, hasWarned: false, hasNagged: false })
      note($, `armed (context ${percent}%)`)
    }

    return
  }

  if (fill < 1) {
    if (state.isArmed && !state.hasWarned) {
      await patch($, { hasWarned: true })
      $.ui.toast(`context ${percent}%. Handoff and compaction start at ${config.limitPercent}%.`)
    }

    return
  }

  if (!state.isArmed || config.mode === 'ask') {
    if (!state.hasNagged) {
      await patch($, { hasNagged: true })
      $.ui.toast(
        state.isArmed
          ? `context ${percent}% is at the limit. Run /orch handoff.`
          : `context ${percent}% is at the limit again and did not drop below ${config.warnPercent}% after the last handoff. No new sequence. Run /orch handoff to force one.`,
      )
      note($, `at the limit (context ${percent}%), no sequence: ${state.isArmed ? 'mode ask' : 'not armed'}`)
    }

    return
  }

  await requestHandoff($, `context ${percent}% is at the limit of ${config.limitPercent}%`)
}

/** True while a signaled handoff is recent: its compaction is in the queue, or it ran in the last minutes. */
async function isHandoffFresh($: EngineInterface): Promise<boolean> {
  const state = await sequenceNow($)

  if (state.phase === 'compacting') {
    return true
  }

  return state.lastEnd.startsWith('compacted') && (await $.clock.now()) - state.lastEndAt <= FRESH_WINDOW_MS
}

function sayNotFresh($: EngineInterface, b: OrchBinding): void {
  const text = `the engine compacted with no handoff signal before it. ${b.readmeRel} can be out of date: check it against Linear.`

  note($, text)
  $.ui.toast(`${text}`, { timeoutMs: 15000 })
}

function instructionsOf(e: SessionCompactInput, b: OrchBinding, isFresh: boolean): string {
  const parts = [projectLineOf(b)]

  if (!isFresh) {
    parts.push(
      `No handoff was signaled before this compaction: say in the summary that ${b.readmeRel} can be out of date and must be checked against Linear.`,
    )
  }

  if (e.instructions !== undefined && e.instructions.trim() !== '') {
    parts.push(e.instructions)
  }

  return parts.join('\n\n')
}

/**
 * `/orch new <slug> [goal]`: writes the project's README where none is, then
 * binds as `/orch <slug>` does. A README that exists is never written.
 */
async function create($: EngineInterface, slug: string, goal: string): Promise<{ text: string; context?: readonly string[] }> {
  if (!isNewSlug(slug)) {
    return {
      text: `"${slug}" is not a name for a new project: lowercase letters, digits and "-" only, and not new, off, handoff or done. ${USAGE}`,
    }
  }

  const readmeRel = `${config.root}/${slug}/README.md`
  const readme = `${await $.session.cwd()}/${readmeRel}`

  if (await $.fs.exists(readme)) {
    return { text: `${readmeRel} exists, use /orch ${slug}` }
  }

  await $.fs.write(readme, scaffoldOf(slug, goal, new Date(await $.clock.now()).toISOString()))
  note($, `created ${readmeRel}`)

  const bound = await bind($, slug)

  if (typeof bound === 'string') {
    return { text: `created ${readmeRel}, but the bind failed: ${bound}` }
  }

  return {
    text: [
      `created ${readmeRel}`,
      'lanes/, briefs/ and docs/ are not created: the mod API has no call that makes a folder. Each one appears when its first file is written.',
      ...(bound.goal === GOAL_TODO ? ['no goal was typed: write it in the README frontmatter, then run /orch ' + slug] : []),
      describe(bound),
    ].join('\n'),
    context: [roleMessageOf(bound)],
  }
}

async function onCommand($: EngineInterface, args: string): Promise<{ text: string; context?: readonly string[] }> {
  const word = args.trim()
  const b = await bindingNow($)

  if (word === '') {
    const slugs = await slugsOf($)

    return {
      text: [
        b === null ? 'not bound' : describe(b),
        ...(b === null ? [] : describeSequence(await sequenceNow($), await $.clock.now(), b)),
        `projects: ${slugs.join(', ') || `none under ${config.root}/`}`,
        USAGE,
      ].join('\n'),
    }
  }

  if (/^new(\s|$)/.test(word)) {
    const [, slug = '', ...goal] = word.split(/\s+/)

    return create($, slug, goal.join(' '))
  }

  if (word === 'off') {
    if (b === null) {
      return { text: 'not bound' }
    }

    await unbind($)

    return { text: `unbound from ${b.slug}` }
  }

  if (word === 'handoff') {
    if (b === null) {
      return { text: `not bound. ${USAGE}` }
    }

    const hasStarted = await requestHandoff($, 'by command')

    const state = await sequenceNow($)

    return {
      text: hasStarted
        ? `handoff requested for ${b.slug}. Compaction follows the handoff signal.\ncode: ${state.code}\n${signalHelpOf(b, state.code)}`
        : `a handoff sequence is in flight (${state.phase}). /orch shows where it is.`,
    }
  }

  if (word === 'done') {
    if (b === null) {
      return { text: `not bound. ${USAGE}` }
    }

    const state = await sequenceNow($)

    if (state.phase === 'compacting') {
      return {
        text: `the handoff signal is in already (${state.signal}); /compact ${state.askedAt > 0 ? 'is in the queue' : 'follows'}.`,
      }
    }

    if (!isOpen(state.phase)) {
      return {
        text: `no handoff sequence is open${state.lastEnd === '' ? '' : ` (last sequence: ${state.lastEnd})`}. /orch handoff starts one.`,
      }
    }

    if ((await signal($, state.code, 'the person, /orch done', '')) !== 'ok') {
      return { text: 'the sequence moved on while this command ran. /orch shows where it is.' }
    }

    stepSoon($)

    return { text: `handoff marked as written by hand for ${b.slug}. /compact runs between turns, then the restart prompt.` }
  }

  const bound = await bind($, word)

  if (typeof bound === 'string') {
    return { text: bound }
  }

  return {
    text: describe(bound),
    context: [roleMessageOf(bound)],
  }
}

type ToolAnswer = { result: string } | { deny: string }

/** A `handoff_done` call for the project this session is bound to: the main loop's, a subagent's or a teammate's. */
async function signalHere(
  $: EngineInterface,
  b: OrchBinding,
  code: string,
  detail: string,
  agentId: string | undefined,
): Promise<ToolAnswer> {
  const verdict = await signal($, code, agentId === undefined ? `tool ${TOOL_NAME}` : `tool ${TOOL_NAME}, agent ${agentId}`, detail)
  const state = await sequenceNow($)

  if (verdict === 'ok') {
    stepSoon($)

    return {
      result: `accepted: the handoff of ${b.slug} is signaled. The orch mod compacts the orchestrator session between turns. Stop now: do not start new work.`,
    }
  }

  if (verdict === 'used') {
    return {
      deny: `code ${code} was used already for ${b.slug}: the signal is in${state.phase === 'compacting' ? ' and the compaction is in the queue' : ''}. Do not call again.`,
    }
  }

  if (verdict === 'wrong') {
    return {
      deny: `wrong code for ${b.slug}: ${code} is not the code of the open handoff request. Nothing changed. The person reads the open code with /orch.`,
    }
  }

  return {
    deny: `no handoff sequence is open for ${b.slug}${state.lastEnd === '' ? '' : ` (last sequence: ${state.lastEnd})`}. Nothing changed. /orch handoff starts one.`,
  }
}

/**
 * A `handoff_done` call in a session that is not the project's orchestrator
 * (a lane in a process of its own): checks the code against the orchestrator's
 * open record, leaves a record for its mod, and sends it a message.
 */
async function relay(
  $: EngineInterface,
  b: OrchBinding | null,
  slug: string,
  code: string,
  detail: string,
): Promise<ToolAnswer> {
  const open = await $.store.get(openKeyOf(slug))
  const here = b === null ? 'This session is not bound to a project' : `This session is bound to ${b.slug}`

  if (!isOpenRecord(open)) {
    return {
      deny: `no handoff sequence is open for "${slug}" on this machine. ${here}. Nothing changed. Check the slug; where the handoff request names a marker file, write the code there.`,
    }
  }

  if (open.code !== code) {
    return { deny: `wrong code for ${slug}: ${code} is not the code of the open handoff request. Nothing changed.` }
  }

  const from = await $.session.id()
  const record: OrchDoneRecord = { code, at: await $.clock.now(), note: detail, from }

  await $.store.set(doneKeyOf(slug), record)

  let failure = ''

  try {
    const sent = await $.session.send({ to: { sessionId: open.sessionId }, text: `${RELAY_MARK} slug=${slug} code=${code}` })

    failure = sent.isDelivered ? '' : sent.reason
  } catch (error) {
    failure = messageOf(error)
  }

  note($, `${TOOL_NAME} for ${slug} relayed to session ${open.sessionId}: ${failure === '' ? 'delivered' : `record only (${failure})`}`)

  return {
    result:
      failure === ''
        ? `accepted: relayed to the orchestrator session of ${slug}. It compacts between turns. Stop now.`
        : `accepted: recorded for the orchestrator session of ${slug}; its mod reads the record in ${POLL_MS / 1000} s or at its next turn end (the direct message was not delivered: ${failure}). Stop now.`,
  }
}

export const register: Register = (on, options) => {
  config = configOf(options)

  on('session.start', async ($, e, next) => {
    isInteractive = e.isInteractive
    held = null
    boundNow = undefined
    cancelTick()

    await $.command.register({
      name: 'orch',
      description: 'Bind this session to an orchestrator project, or run handoff and compaction now',
      argumentHint: '[slug | new <slug> [goal] | off | handoff | done]',
    })
    // In every session, bound or not: a lane's or a scribe's own session makes the call too.
    await $.tool.register({
      name: TOOL_NAME,
      description: TOOL_TEXT,
      inputSchema: {
        type: 'object',
        properties: {
          slug: { type: 'string', description: 'The project slug, as the handoff request gives it.' },
          code: { type: 'string', description: 'The one-time code of the handoff request.' },
          note: { type: 'string', description: 'Optional: one line on what was written.' },
        },
        required: ['slug', 'code'],
      },
    })

    const b = await bindingNow($)

    if (b !== null) {
      showStatus($, b, await percentNow($))
    }

    // A reload drops the timers of the module it replaces; the sequence is in `$.state`.
    const state = await sequenceNow($)

    if (isOpen(state.phase) && state.phase !== 'compacting' && state.code === '') {
      // Version 0.2 waited for the README to change and gave no code: nothing can signal this one.
      await stop($, `the sequence was started by an older version of the mod and has no code (phase ${state.phase})`, 'Run /orch handoff.')
    } else if (isOpen(state.phase)) {
      note($, `sequence open at the start of this load (${state.phase}); continuing`)
      armTick($, state)
    }

    return next(e)
  })

  on('command.run', { command: 'orch' }, async ($, e) => {
    try {
      return await onCommand($, e.args)
    } catch (error) {
      note($, `/orch ${e.args} failed: ${messageOf(error)}`)

      return { text: `failed: ${messageOf(error)}` }
    }
  })

  // Listed, not behind ToolSearch: a lane or a subagent calls it by the name the handoff request gives.
  on('tool.describe', { tool: TOOL }, async ($, e, next) => ({ ...(await next(e)), isDeferred: false }))

  on('tool.call', { tool: TOOL }, async ($, e): Promise<ToolAnswer> => {
    const input = e as unknown as Record<string, unknown>
    const slug = typeof input.slug === 'string' ? input.slug.trim() : ''
    const code = typeof input.code === 'string' ? input.code.trim().toLowerCase() : ''
    const detail = typeof input.note === 'string' ? input.note.trim() : ''

    try {
      if (slug === '' || code === '') {
        return { deny: `${TOOL_NAME} takes slug and code, as the handoff request gives them. Nothing changed.` }
      }

      const b = await bindingNow($)

      return b !== null && b.slug === slug
        ? await signalHere($, b, code, detail, e.agentId)
        : await relay($, b, slug, code, detail)
    } catch (error) {
      note($, `${TOOL_NAME} failed: ${messageOf(error)}`)

      return { deny: `${TOOL_NAME} failed: ${messageOf(error)}. Nothing changed.` }
    }
  })

  // The message a handoff_done call in another session sends here. The model never reads it.
  on('session.receive', async ($, e, next) => {
    const match = e.agentId === undefined ? /\[orch-handoff-done\] slug=(\S+) code=([a-z0-9-]+)/.exec(e.text) : null

    if (match === null) {
      return next(e)
    }

    const slug = match[1] ?? ''
    const code = match[2] ?? ''

    try {
      const b = await bindingNow($)

      if (b === null || b.slug !== slug) {
        note($, `a handoff relay for ${slug} came here; this session is ${b === null ? 'not bound' : `bound to ${b.slug}`}: ignored`)
      } else {
        const verdict = await signal($, code, 'relay from another session', '')

        if (verdict === 'ok') {
          stepSoon($)
        } else {
          note($, `a handoff relay for ${slug} did not count (${verdict})`)
        }
      }
    } catch (error) {
      note($, `the handoff relay failed: ${messageOf(error)}`)
    }

    return { consumed: 'orch: handoff relay' }
  })

  on('prompt.submit', async ($, e, next) => {
    const isPersons = e.origin.kind === 'composer' || e.origin.kind === 'bridge' || e.origin.kind === 'sdk'

    if (isPersons && (await bindingNow($)) === null) {
      try {
        const bound = await autoBind($, e.text)

        if (bound !== null) {
          return next({ ...e, context: [...(e.context ?? []), roleMessageOf(bound)] })
        }
      } catch (error) {
        note($, `bind from the prompt failed: ${messageOf(error)}`)
      }
    }

    return next(e)
  })

  on('prompt.compose', async ($, e, next) => {
    const composed = await next(e)

    if (e.traits.includes('teammate')) {
      return composed
    }

    const b = await bindingNow($)

    if (b === null) {
      return composed
    }

    return {
      sections: [
        ...composed.sections.filter(section => section.id !== SECTION_ID),
        { id: SECTION_ID, text: roleOf(b), scope: 'session' },
      ],
    }
  })

  on('session.measure', async ($, e, next) => {
    try {
      await onMeasure($, e)
    } catch (error) {
      note($, `the measure step failed: ${messageOf(error)}`)
    }

    return next(e)
  })

  on('turn.start', async ($, e, next) => {
    const state = await sequenceNow($)

    if (state.phase === 'requested' && e.text.includes(HANDOFF_MARK)) {
      await patch($, { phase: 'running', turnId: e.turnId })
      note($, 'handoff turn started')
    }

    return next(e)
  })

  on('turn.complete', async ($, e, next) => {
    const done = await next(e)

    if (e.agentId !== undefined) {
      return done
    }

    try {
      const at = await $.clock.now()
      const state = held ?? (await sequenceNow($))

      if (!isOpen(state.phase) || (state.phase === 'compacting' && state.askedAt > 0)) {
        return done
      }

      const isHandoffTurn = state.phase === 'running' && state.turnId === e.turnId

      if (isHandoffTurn && e.reason !== 'answer') {
        await stop($, `the handoff turn ended (${e.reason})`, 'No compaction. Run /orch handoff.')

        return done
      }

      if (isHandoffTurn) {
        // No signal came in the handoff turn: the wait for it starts here.
        await patch($, { phase: 'waiting', phaseAt: at })
        note(
          $,
          `handoff turn ended with no signal. Waiting ${minutesOf(config.waitMs)} minutes for ${TOOL_NAME} with code ${state.code} (a delegated write lands later).`,
        )
      }

      if (isInteractive) {
        // In this dispatch: a /compact goes into the queue ahead of each prompt that comes after this turn.
        await step($)
      } else {
        $.clock.after(SETTLE_MS, () => {
          void step($)
        })
      }
    } catch (error) {
      note($, `the turn end step failed: ${messageOf(error)}`)
    }

    return done
  })

  on('session.compact', async ($, e, next) => {
    if (e.agentId !== undefined || e.trigger === 'plugin') {
      return next(e)
    }

    let b = await bindingNow($)

    if (b === null && e.trigger === 'manual' && e.instructions !== undefined) {
      b = await autoBind($, e.instructions)
    }

    if (b === null) {
      return next(e)
    }

    const bound = b
    const isOwn = e.trigger === 'manual' && e.instructions !== undefined && e.instructions.includes(OWN_MARK)
    const isFresh = e.trigger === 'manual' || (await isHandoffFresh($))
    const compacted = await next({ ...e, instructions: instructionsOf(e, bound, isFresh) })

    if (isOwn) {
      ownOutcome =
        compacted.skip === undefined
          ? { isDone: true, reason: `${compacted.tokensBefore ?? '?'} to ${compacted.tokensAfter ?? '?'} tokens` }
          : { isDone: false, reason: `skipped: ${compacted.skip}` }
      $.clock.after(0, () => {
        void settle($, '/compact ran and did not compact')
      })
    } else if (compacted.skip === undefined && e.trigger !== 'precompute') {
      const state = await sequenceNow($)

      // A sequence whose /compact is in the queue stays open: that command still runs.
      if (state.phase === 'waiting' || (state.phase === 'compacting' && state.askedAt === 0)) {
        await stop(
          $,
          `${e.trigger === 'manual' ? 'the person' : 'the engine'} compacted in phase ${state.phase}`,
          `Check ${bound.readmeRel}.`,
        ).catch((error: unknown) => {
          note($, `the sequence state did not reset: ${messageOf(error)}`)
        })
      }
    }

    if (e.trigger === 'auto' && !isFresh && compacted.skip === undefined) {
      $.clock.after(0, () => {
        sayNotFresh($, bound)
      })
    }

    return compacted
  })
}
