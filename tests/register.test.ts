import type { On } from 'claude-code'
import { describe, expect, test } from 'claude-code/testing'
import type { Engine } from 'claude-code/testing'

import type { OrchBinding, OrchSequence } from '../types'
import {
  FRONTMATTER,
  HEADLESS,
  MARKER,
  OLD,
  README,
  SESSION,
  SESSION_ID,
  START,
  TOOL,
  compaction,
  done,
  measureAt,
  orch,
  relayed,
  turnEnd,
  typed,
  worldOf,
} from './fixtures/world'

const TAG = '[orch-role demo]'
const HANDOFF = '[orch] Update the handoff now'
const RESTART = 'Read /work/.remember/demo/README.md and continue as orchestrator for demo.'
const PICKUP = "you're the orchestrator for the demo project. Pick up from your handoff @.remember/demo/README.md"

const demo = () => ({ [README]: { text: FRONTMATTER, mtimeMs: OLD } })

async function bound($: Engine, on: On, session = SESSION) {
  const world = worldOf(on, demo())

  await $.session.start(session)
  await $.command.run(orch('demo'))

  return world
}

/** The role message the next prompt (a background task's notification: it binds nothing) carries, if any. */
async function roleOf($: Engine) {
  const entered = await $.prompt.submit({ ...typed('a task ended'), origin: { kind: 'task-notification' } })

  return entered.context?.find(entry => entry.startsWith('[orch-role '))
}

const OWN = 'The handoff file was updated before this compaction.'
const LINE =
  'Orchestrator for demo: Move the API and the CLI from Python to Go. Keep: open lanes, pending decisions, in-flight PRs and tickets, restart steps. Entry point .remember/demo/README.md.'
/** The arguments of the /compact the mod asks for. */
const ASKED = `${OWN}\n\n${LINE}`

/** The one-time code the mod wrote into its handoff prompt (the last one it submitted). */
const codeOf = (world: { seen: { prompts: string[] } }) =>
  /code "([a-z2-9]{4}-[a-z2-9]{4})"/.exec(world.seen.prompts.filter(text => text.startsWith(HANDOFF)).at(-1) ?? '')?.[1] ?? ''

/**
 * Brings a bound session to a handoff turn that is running as turn `t1`. The
 * /compact command compacts as the engine's does: a compaction of the person's.
 */
async function atHandoffTurn($: Engine, on: On, session = SESSION) {
  const world = await bound($, on, session)

  world.runCompact = args => $.session.compact(compaction({ instructions: args }))
  await $.session.measure(measureAt(56))
  await world.clock.settle()
  await $.turn.start({ text: world.seen.prompts[0] ?? '', turnId: 't1' })

  return world
}

describe('register', () => {
  describe('bind', () => {
    test('/orch <slug> binds, shows the project and sets the status', async ($, on) => {
      const world = worldOf(on, demo())

      await $.session.start(SESSION)
      const ran = await $.command.run(orch('demo'))

      expect(ran.text).toContain('bound to demo (.remember/demo/README.md, 13 lines)')
      expect(ran.text).toContain('goal: Move the API and the CLI from Python to Go')
      expect(ran.text).toContain('linear: Dev Health Ops')
      expect(ran.text).not.toContain('frontmatter missing')
      expect(ran.context, 'the role rides the bind until the next compaction').toHaveLength(1)
      expect(ran.context?.[0]).toContain('orchestrator project demo')
      expect(ran.context?.[0]).toContain('You are the orchestrator for project `demo`')
      expect(world.seen.status.at(-1)).toBe('demo 10/55%')
    })

    test('a README with no frontmatter binds on its heading and says which keys to add', async ($, on) => {
      worldOf(on, { [README]: { text: '# Demo entry point\n', mtimeMs: OLD } })

      await $.session.start(SESSION)
      const ran = await $.command.run(orch('demo'))

      expect(ran.text).toContain('goal: Demo entry point')
      expect(ran.text).toContain('frontmatter missing')
      expect(ran.text).toContain('goal, linear_project, canonical, role')
    })

    test('a README longer than the limit is bound with a warning', async ($, on) => {
      worldOf(on, { [README]: { text: `# Demo\n${'line\n'.repeat(400)}`, mtimeMs: OLD } })

      await $.session.start(SESSION)

      expect((await $.command.run(orch('demo'))).text).toContain('warning: the README has 401 lines (limit 300)')
    })

    test('a slug with no README binds nothing and lists the projects', async ($, on) => {
      const world = worldOf(on, demo())

      await $.session.start(SESSION)
      const ran = await $.command.run(orch('nope'))

      expect(ran.text).toBe('.remember/nope/README.md does not exist: create it with /orch new nope. projects: demo')
      expect(await roleOf($)).toBeUndefined()
      expect(world.seen.status).toEqual([])
    })

    test('a word that is not one path part binds nothing', async ($, on) => {
      const world = worldOf(on, { ...demo(), '/work/README.md': { text: '# Outside\n', mtimeMs: OLD } })

      await $.session.start(SESSION)

      expect((await $.command.run(orch('..'))).text).toContain('is not a project name')
      expect((await $.command.run(orch('demo/../demo'))).text).toContain('is not a project name')
      expect(world.seen.status).toEqual([])
    })

    test('/orch alone shows the binding and the projects; /orch off unbinds', async ($, on) => {
      const world = worldOf(on, {
        ...demo(),
        '/work/.remember/other/README.md': { text: '# Other\n', mtimeMs: OLD },
        '/work/.remember/logs/x.log': { text: '', mtimeMs: OLD },
      })

      await $.session.start(SESSION)

      expect((await $.command.run(orch(''))).text).toContain('not bound\nprojects: demo, other')

      await $.command.run(orch('demo'))

      expect((await $.command.run(orch(''))).text).toContain('bound to demo (')
      expect((await $.command.run(orch('off'))).text).toBe('unbound from demo')
      expect(world.seen.status.at(-1)).toBeUndefined()
      expect(await roleOf($)).toBeUndefined()
    })

    test("the person's prompt that names one README and the orchestrator role binds", async ($, on) => {
      const world = worldOf(on, demo())

      await $.session.start(SESSION)
      await $.prompt.submit(typed(PICKUP))

      expect(world.seen.typed).toEqual([PICKUP])
      expect(world.seen.typedContext, 'the role rides the prompt that bound').toHaveLength(1)
      expect(world.seen.typedContext[0]).toContain('You are the orchestrator for project `demo`')
      expect(world.seen.toasts.join('\n')).toContain('bound to demo from your prompt')

      await $.prompt.submit(typed(PICKUP))

      expect(world.seen.typedContext, 'once: the conversation holds the role').toHaveLength(1)
      expect(await roleOf($)).toBeUndefined()
    })

    test('a prompt binds nothing without the role word, with two projects, with no such project, or from a lane', async ($, on) => {
      const world = worldOf(on, { ...demo(), '/work/.remember/other/README.md': { text: '# Other\n', mtimeMs: OLD } })

      await $.session.start(SESSION)
      await $.prompt.submit(typed('what is in .remember/demo/README.md?'))

      expect(await roleOf($), 'no role word').toBeUndefined()

      await $.prompt.submit(typed(`${PICKUP} and the orchestrator of .remember/other/README.md`))

      expect(await roleOf($), 'two projects').toBeUndefined()

      await $.prompt.submit(typed('orchestrator: see .remember/gone/README.md'))

      expect(await roleOf($), 'no such project').toBeUndefined()

      await $.prompt.submit({ ...typed(PICKUP), origin: { kind: 'task-notification' } })

      expect(await roleOf($), 'not the person').toBeUndefined()
      expect(world.seen.typedContext).toEqual([])
      expect(world.seen.status).toEqual([])
    })

    test('a prompt does not move a session that is bound', async ($, on) => {
      const world = worldOf(on, { ...demo(), '/work/.remember/other/README.md': { text: '# Other\n', mtimeMs: OLD } })

      await $.session.start(SESSION)
      await $.command.run(orch('other'))
      await $.prompt.submit(typed(PICKUP))

      expect(world.seen.typedContext).toHaveLength(1)
      expect(world.seen.typedContext[0]).toStartWith('[orch-role other] ')
      expect(world.seen.toasts.join('\n')).not.toContain('from your prompt')
    })
  })

  describe('new project', () => {
    const NEW = '/work/.remember/demo2/README.md'

    test('/orch new <slug> <goal> writes the README, then binds with the role', async ($, on) => {
      const world = worldOf(on, demo())

      await $.session.start(SESSION)
      const ran = await $.command.run(orch('new demo2   Ship the "v2" API: fast'))

      expect(world.seen.writes).toEqual([NEW])
      expect(world.files[NEW]?.text).toStartWith(
        '---\ngoal: "Ship the \\"v2\\" API: fast"\nlinear_project: ""\ncanonical: []\n---\n# demo2\n\nlast updated: 1970-01-01T00:16:40.000Z\n',
      )
      expect(ran.text).toStartWith('created .remember/demo2/README.md\n')
      expect(ran.text).toContain('lanes/, briefs/ and docs/ are not created')
      expect(ran.text).toContain('bound to demo2 (.remember/demo2/README.md, 25 lines)')
      expect(ran.text).toContain('goal: Ship the "v2" API: fast')
      expect(ran.text).not.toContain('frontmatter missing')
      expect(ran.text).not.toContain('no goal was typed')
      expect(ran.context?.[0]).toContain('You are the orchestrator for project `demo2`: Ship the "v2" API: fast')
      expect(world.seen.logs).toContain('created .remember/demo2/README.md')
      expect(world.seen.status.at(-1)).toBe('demo2 10/55%')
      expect(await roleOf($)).toContain('project `demo2`')
    })

    test('/orch new <slug> with no goal writes a visible TODO and says so', async ($, on) => {
      const world = worldOf(on, demo())

      await $.session.start(SESSION)
      const ran = await $.command.run(orch('new demo2'))

      expect(world.files[NEW]?.text).toContain('goal: "TODO: write the goal of this project"')
      expect(ran.text).toContain('no goal was typed')
      expect(ran.text).toContain('goal: TODO: write the goal of this project')
      expect(world.seen.status.at(-1)).toBe('demo2 10/55%')
    })

    test('a README that exists is never written: the answer names /orch <slug>', async ($, on) => {
      const world = worldOf(on, demo())

      await $.session.start(SESSION)
      const ran = await $.command.run(orch('new demo another goal'))

      expect(ran.text).toBe('.remember/demo/README.md exists, use /orch demo')
      expect(world.seen.writes).toEqual([])
      expect(world.files[README]).toEqual({ text: FRONTMATTER, mtimeMs: OLD })
      expect(world.seen.status, 'and nothing is bound').toEqual([])
    })

    test('a folder that exists with no README gets the README only', async ($, on) => {
      const lane = '/work/.remember/demo2/lanes/l1.md'
      const world = worldOf(on, { ...demo(), [lane]: { text: 'lane notes', mtimeMs: OLD } })

      await $.session.start(SESSION)
      const ran = await $.command.run(orch('new demo2 a goal'))

      expect(world.seen.writes).toEqual([NEW])
      expect(world.files[lane]).toEqual({ text: 'lane notes', mtimeMs: OLD })
      expect(ran.text).toContain('bound to demo2')
    })

    test('a name outside the rule, or a command word, creates nothing', async ($, on) => {
      const world = worldOf(on, demo())

      await $.session.start(SESSION)

      for (const name of ['Demo', 'a.b', 'a/b', '../x', '-x', 'a_b', 'new', 'off', 'handoff', 'done']) {
        const ran = await $.command.run(orch(`new ${name} some goal`))

        expect(ran.text, name).toContain(`"${name}" is not a name for a new project`)
      }

      expect((await $.command.run(orch('new'))).text).toContain('"" is not a name for a new project')
      expect((await $.command.run(orch('new'))).text).toContain('/orch new <slug> [goal]')
      expect(world.seen.writes).toEqual([])
      expect(world.seen.status).toEqual([])
    })

    test('a write that fails shows the reason and binds nothing', async ($, on) => {
      const world = worldOf(on, demo())

      world.writeError = 'EACCES: permission denied'
      await $.session.start(SESSION)
      const ran = await $.command.run(orch('new demo2 a goal'))

      expect(ran.text).toContain('failed:')
      expect(ran.text).toContain('EACCES: permission denied')
      expect(world.seen.logs.join('\n')).toContain('EACCES: permission denied')
      expect(world.seen.logs.join('\n')).not.toContain('created')
      expect(world.seen.status).toEqual([])
      expect(await roleOf($)).toBeUndefined()
    })

    test('/orch <slug> on a missing project names /orch new only when the name fits the rule', async ($, on) => {
      worldOf(on, demo())

      await $.session.start(SESSION)

      expect((await $.command.run(orch('orch-mod'))).text).toContain(
        '.remember/orch-mod/README.md does not exist: create it with /orch new orch-mod.',
      )
      expect((await $.command.run(orch('Orch.Mod'))).text).toContain('.remember/Orch.Mod/README.md does not exist. projects:')
      expect((await $.command.run(orch(''))).text).toContain('/orch new <slug> [goal]')
    })

    test('a project whose name starts with the word new is bound, not created', async ($, on) => {
      const world = worldOf(on, { ...demo(), '/work/.remember/newer/README.md': { text: '# Newer\n', mtimeMs: OLD } })

      await $.session.start(SESSION)

      expect((await $.command.run(orch('newer'))).text).toContain('bound to newer')
      expect(world.seen.writes).toEqual([])
    })
  })

  describe('role', () => {
    test('a bound session: the next prompt carries the role message, tagged; a prompt after it carries none', async ($, on) => {
      const world = await bound($, on)

      await $.prompt.submit(typed('status?'))

      const [role] = world.seen.typedContext

      expect(world.seen.typedContext).toHaveLength(1)
      expect(role).toStartWith(`${TAG} The orch mod bound this session to orchestrator project demo. The orch mod repeats this message after each compaction.`)
      expect(role).not.toContain('system prompt')
      expect(role).toContain('Move the API and the CLI from Python to Go')
      expect(role).toContain('(project: Dev Health Ops)')
      expect(role).toContain('- Linear document "Go cutover TRD" is the plan of record')
      expect(role).toContain('stay below 55% context')
      expect(role).toContain('One lane for each PR.')

      await $.prompt.submit(typed('and now?'))

      expect(world.seen.typedContext, 'the conversation holds the tag').toHaveLength(1)
    })

    test('every kind of prompt carries the role while the conversation lacks it', async ($, on) => {
      await bound($, on)

      const entered = await $.prompt.submit({ ...typed('hi'), origin: { kind: 'peer' } })

      expect(entered.context).toEqual([expect.stringContaining(TAG)])
      expect(await roleOf($), 'the peer prompt left it').toBeUndefined()
    })

    test('a prompt that runs a slash command carries no role', async ($, on) => {
      await bound($, on)

      const entered = await $.prompt.submit({ ...typed('/review'), command: { name: 'review', args: '' } })

      expect(entered.context).toBeUndefined()
      expect(await roleOf($), 'the next prompt does').toContain(TAG)
    })

    test('a compaction drops the tag with the rows: the next prompt carries the role again', async ($, on) => {
      const world = await bound($, on)

      await $.prompt.submit(typed('status?'))
      await $.session.compact(compaction({}))

      expect(world.messages.map(row => row.text)).toEqual(['the summary'])
      expect(await roleOf($)).toContain(TAG)
    })

    test('an unbound session carries no role, no status and takes no action at any fill', async ($, on) => {
      const world = worldOf(on, demo())

      await $.session.start(SESSION)
      await $.session.measure(measureAt(90))
      await world.clock.settle()
      await $.prompt.submit(typed('status?'))

      expect(world.seen.typedContext).toEqual([])
      expect(await roleOf($)).toBeUndefined()
      expect(world.seen.status).toEqual([])
      expect(world.seen.toasts).toEqual([])
      expect(world.seen.logs).toEqual([])
      expect(world.seen.prompts).toEqual([])

      await $.session.compact(compaction({ instructions: 'keep the plan' }))

      expect(world.seen.compacts[0]?.instructions).toBe('keep the plan')
    })
  })

  describe('limit', () => {
    test('the status follows the fill, and the warning shows once', async ($, on) => {
      const world = await bound($, on)

      await $.session.measure(measureAt(30))
      await $.session.measure(measureAt(46))
      await $.session.measure(measureAt(50))

      expect(world.seen.status.at(-1)).toBe('demo 50/55%')
      expect(world.seen.toasts.filter(text => text.includes('start at 55%'))).toHaveLength(1)
      expect(world.seen.prompts).toEqual([])
    })

    test('the limit submits the handoff prompt once', async ($, on) => {
      const world = await bound($, on)

      await $.session.measure(measureAt(56))
      await world.clock.settle()
      await $.session.measure(measureAt(57))
      await world.clock.settle()

      expect(world.seen.prompts).toHaveLength(1)
      expect(world.seen.prompts[0]).toStartWith(HANDOFF)
      expect(world.seen.prompts[0]).toContain('in /work/.remember/demo/README.md')
    })

    test('the handoff request names the tool, the slug, a one-time code and the marker file', async ($, on) => {
      const world = await bound($, on)

      await $.session.measure(measureAt(56))
      await world.clock.settle()

      const code = codeOf(world)

      expect(code).toMatch(/^[a-z2-9]{4}-[a-z2-9]{4}$/)
      expect(world.seen.prompts[0]).toContain(`call the tool ${TOOL} with slug "demo" and code "${code}"`)
      expect(world.seen.prompts[0]).toContain('a scribe or a lane writes the handoff, give it the slug and the code')
      expect(world.seen.prompts[0]).toContain(`write the code into the file ${MARKER}`)
      expect(world.seen.prompts[0]).toContain('ends 10 minutes after this turn')
      expect(world.store['open/demo'], 'what a call in another session reads').toEqual({
        code,
        sessionId: SESSION_ID,
        at: START,
      })
    })

    test('the token limit starts the sequence below the percent limit', async ($, on) => {
      const world = await bound($, on)

      await $.session.measure(measureAt(20, 300_000))
      await world.clock.settle()

      expect(world.seen.prompts).toEqual([])
    })

    test(
      'with a token limit set, the tokens start the sequence below the percent limit',
      { options: { limitTokens: 250_000 } },
      async ($, on) => {
        const world = await bound($, on)

        await $.session.measure(measureAt(20, 300_000))
        await world.clock.settle()

        expect(world.seen.prompts).toHaveLength(1)
      },
    )

    test('mode ask shows one message and submits nothing until /orch handoff', { options: { mode: 'ask' } }, async ($, on) => {
      const world = await bound($, on)

      await $.session.measure(measureAt(56))
      await $.session.measure(measureAt(57))
      await world.clock.settle()

      expect(world.seen.prompts).toEqual([])
      expect(world.seen.toasts.filter(text => text.includes('Run /orch handoff'))).toHaveLength(1)

      expect((await $.command.run(orch('handoff'))).text).toContain('handoff requested for demo')
      await world.clock.settle()

      expect(world.seen.prompts).toHaveLength(1)
      expect((await $.command.run(orch('handoff'))).text).toContain('in flight (requested)')
    })

    test('mode off keeps the status and does nothing at the limit', { options: { mode: 'off' } }, async ($, on) => {
      const world = await bound($, on)

      await $.session.measure(measureAt(80))
      await world.clock.settle()

      expect(world.seen.status.at(-1)).toBe('demo 80/55%')
      expect(world.seen.toasts).toEqual([])
      expect(world.seen.prompts).toEqual([])
    })

    test('/orch handoff in an unbound session starts nothing', async ($, on) => {
      const world = worldOf(on, demo())

      await $.session.start(SESSION)

      expect((await $.command.run(orch('handoff'))).text).toContain('not bound')
      await world.clock.settle()
      expect(world.seen.prompts).toEqual([])
    })
  })

  describe('handoff then compact', () => {
    const MINUTE = 60 * 1000
    const logsOf = (world: { seen: { logs: string[] } }) => world.seen.logs.join('\n')
    const toastsOf = (world: { seen: { toasts: string[] } }) => world.seen.toasts.join('\n')
    const shown = async ($: Engine) => (await $.command.run(orch(''))).text ?? ''

    test('handoff_done in the handoff turn: /compact is asked for after the call, one compaction stands, the restart prompt follows', async ($, on) => {
      const world = await atHandoffTurn($, on)
      const answer = await $.tool.call(done('demo', codeOf(world), { note: 'README and lanes written' }))

      expect(answer.deny).toBeUndefined()
      expect(String(answer.result)).toContain('accepted: the handoff of demo is signaled')
      expect(world.seen.commands, 'not inside the tool call: the turn waits on that hook').toEqual([])
      expect(world.store['open/demo'], 'a later call in another session finds no open sequence').toBeUndefined()

      await world.clock.settle()

      expect(world.seen.commands, 'asked for while the handoff turn still runs: it waits in the queue').toEqual([ASKED])
      expect(world.seen.compacts).toHaveLength(1)
      expect(world.seen.compacts[0]?.trigger).toBe('manual')
      expect(world.seen.compacts[0]?.instructions, 'the project line once').toBe(ASKED)
      expect(world.seen.compacts[0]?.instructions).not.toContain('No handoff was signaled')

      await $.turn.complete(turnEnd('t1'))
      await world.clock.settle()

      expect(world.seen.commands, 'the turn end asks for nothing more').toEqual([ASKED])
      expect(world.seen.prompts).toEqual([expect.stringContaining(HANDOFF), expect.stringContaining(RESTART)])
      expect(logsOf(world)).toContain('handoff signal received (tool handoff_done): README and lanes written')
      expect(logsOf(world)).toContain('handoff signaled; /compact asked for')
      expect(logsOf(world)).toContain('sequence ended: compacted (900 to 100 tokens)')
      expect(toastsOf(world), 'a sequence that compacted is not a stop').not.toContain('stopped')
      expect(await shown($)).toContain('last sequence: compacted (900 to 100 tokens)')
    })

    // A managed plugin (sec-default) holds session.compact from the user tier: the mod's hook never runs.
    test('a held compaction hook: rows that drop under /compact count as compacted, and the restart prompt carries the role', async ($, on) => {
      const world = await atHandoffTurn($, on)

      world.messages.push({ role: 'assistant', text: 'written', toolUses: [] }, { role: 'user', text: 'more', toolUses: [] })
      world.runCompact = async () => {
        world.messages = [{ role: 'user', text: 'the summary', toolUses: [] }]
      }
      await $.tool.call(done('demo', codeOf(world)))
      await world.clock.settle()

      expect(world.seen.commands).toEqual([ASKED])
      expect(world.seen.compacts, 'the hook did not run').toEqual([])
      expect(logsOf(world)).toContain('sequence ended: compacted (rows 3 to 1)')
      expect(world.seen.prompts.at(-1), 'the summary dropped the tag; the restart prompt carries the role').toStartWith(
        `${RESTART}\n\n${TAG} The orch mod bound this session to orchestrator project demo. The orch mod repeats this message after each compaction.\n\n# Orchestrator role (orch mod)`,
      )
      expect(world.seen.prompts.at(-1)).toContain('One lane for each PR.')
      expect(world.seen.promptContext.at(-1)).toEqual([])
      expect(await roleOf($), 'the restart row holds the tag').toBeUndefined()
      expect(toastsOf(world)).not.toContain('stopped')
    })

    test('a held compaction hook: rows that do not drop under /compact stop the sequence with no restart prompt', async ($, on) => {
      const world = await atHandoffTurn($, on)

      world.runCompact = async () => {}
      await $.tool.call(done('demo', codeOf(world)))
      await world.clock.settle()

      expect(world.seen.commands).toEqual([ASKED])
      expect(toastsOf(world)).toContain('handoff sequence stopped: no compaction: /compact ran and did not compact. Run /compact.')
      expect(world.seen.prompts).toEqual([expect.stringContaining(HANDOFF)])
    })

    // webd session 26211431: `lane-wr-scribe` is an Agent-tool subagent of the
    // orchestrator's own session, so its call comes here with its agent id.
    test('handoff_done from a subagent loop of the session is accepted', async ($, on) => {
      const world = await atHandoffTurn($, on)

      await $.turn.complete(turnEnd('t1'))

      const answer = await $.tool.call(done('demo', codeOf(world), { agentId: 'a7' }))

      await world.clock.settle()

      expect(String(answer.result)).toContain('accepted')
      expect(logsOf(world)).toContain('handoff signal received (tool handoff_done, agent a7)')
      expect(world.seen.commands).toEqual([ASKED])
      expect(world.seen.compacts).toHaveLength(1)
      expect(world.seen.prompts.at(-1)).toStartWith(RESTART)
    })

    test('a handoff turn that ends with no call keeps the sequence open and shows the code; a later call compacts', async ($, on) => {
      const world = await atHandoffTurn($, on)
      const code = codeOf(world)

      await $.turn.complete(turnEnd('t1'))
      await world.clock.advance(3 * MINUTE)

      expect(world.seen.commands).toEqual([])
      expect(logsOf(world)).toContain(`handoff turn ended with no signal. Waiting 10 minutes for handoff_done with code ${code}`)

      const text = await shown($)

      expect(text).toContain('sequence: waiting for the handoff signal (3 min of 10 min)')
      expect(text).toContain(`code: ${code}`)
      expect(text).toContain(`signal: call ${TOOL} with slug "demo" and code "${code}", or write the code to .remember/demo/.handoff, or run /orch done`)

      await $.tool.call(done('demo', code))
      await world.clock.settle()

      expect(world.seen.commands).toEqual([ASKED])
      expect(world.seen.prompts.at(-1)).toStartWith(RESTART)
    })

    test('a wrong code is refused and changes nothing', async ($, on) => {
      const world = await atHandoffTurn($, on)
      const answer = await $.tool.call(done('demo', 'zzzz-zzzz'))

      await world.clock.advance(MINUTE)

      expect(answer.deny).toContain('wrong code for demo: zzzz-zzzz is not the code of the open handoff request. Nothing changed.')
      expect(world.seen.commands).toEqual([])
      expect(await shown($)).toContain('sequence: the handoff turn is running')
      expect(world.store['open/demo']).toBeDefined()
    })

    test('a wrong slug is refused and changes nothing', async ($, on) => {
      const world = await atHandoffTurn($, on)
      const answer = await $.tool.call(done('other', codeOf(world)))

      await world.clock.advance(MINUTE)

      expect(answer.deny).toContain('no handoff sequence is open for "other" on this machine. This session is bound to demo. Nothing changed.')
      expect(world.seen.commands).toEqual([])
      expect(world.seen.sent).toEqual([])
      expect(await shown($)).toContain('sequence: the handoff turn is running')
    })

    test('a code is taken once: the second call is refused, while /compact waits and after the sequence', async ($, on) => {
      const world = await atHandoffTurn($, on)
      const code = codeOf(world)

      world.queueMs = MINUTE
      await $.tool.call(done('demo', code))
      await world.clock.settle()

      const again = await $.tool.call(done('demo', code))

      await world.clock.settle()

      expect(again.deny).toContain(`code ${code} was used already for demo: the signal is in and the compaction is in the queue. Do not call again.`)
      expect(world.seen.commands, 'asked for once').toEqual([ASKED])

      await world.clock.advance(MINUTE)

      expect(world.seen.compacts).toHaveLength(1)

      const late = await $.tool.call(done('demo', code))

      expect(late.deny).toContain(`code ${code} was used already for demo: the signal is in. Do not call again.`)
      expect(world.seen.commands).toEqual([ASKED])
      expect(world.seen.prompts.filter(text => text.startsWith(RESTART))).toHaveLength(1)
    })

    test('a call with no sequence open, or with no slug or code, is refused and changes nothing', async ($, on) => {
      const world = await bound($, on)
      const idle = await $.tool.call(done('demo', 'abcd-efgh'))
      const bare = await $.tool.call(done('demo', ''))

      await world.clock.advance(MINUTE)

      expect(idle.deny).toContain('no handoff sequence is open for demo. Nothing changed. /orch handoff starts one.')
      expect(bare.deny).toContain('handoff_done takes slug and code')
      expect(world.seen.commands).toEqual([])
      expect(world.seen.prompts).toEqual([])
    })

    test('no call: the sequence stops at the time limit with no compaction, a toast and a log line; a late call is refused', async ($, on) => {
      const world = await atHandoffTurn($, on)
      const code = codeOf(world)

      await $.turn.complete(turnEnd('t1'))
      await world.clock.advance(9 * MINUTE)

      expect(toastsOf(world), 'inside the ten minutes the sequence stays open').not.toContain('stopped')

      await world.clock.advance(2 * MINUTE)

      expect(world.seen.commands).toEqual([])
      expect(world.seen.prompts).toHaveLength(1)
      expect(toastsOf(world)).toContain(
        `handoff sequence stopped: no handoff signal: handoff_done was not called with code ${code} in 10 minutes after the handoff turn. No compaction.`,
      )
      expect(logsOf(world)).toContain('sequence ended: no handoff signal')

      const text = await shown($)

      expect(text).toContain('sequence: idle (not armed')
      expect(text).toContain('last sequence: no handoff signal: handoff_done was not called')
      expect(world.store['open/demo'], 'the open record is withdrawn').toBeUndefined()

      const late = await $.tool.call(done('demo', code))

      await world.clock.advance(MINUTE)

      expect(late.deny).toContain('no handoff sequence is open for demo (last sequence: no handoff signal')
      expect(world.seen.commands, 'a stopped sequence asks for nothing later').toEqual([])
    })

    test('the wait is the configured number of minutes', { options: { handoffWaitMinutes: 2 } }, async ($, on) => {
      const world = await atHandoffTurn($, on)

      expect(world.seen.prompts[0]).toContain('ends 2 minutes after this turn')

      await $.turn.complete(turnEnd('t1'))
      await world.clock.advance(1.5 * MINUTE)

      expect(toastsOf(world)).not.toContain('stopped')

      await world.clock.advance(MINUTE)

      expect(toastsOf(world)).toContain('in 2 minutes after the handoff turn. No compaction.')
    })

    // 0.2 compacted as soon as the README changed. A file time is no signal now.
    test('a README that changes, in the handoff turn and after it, starts no compaction', async ($, on) => {
      const world = await atHandoffTurn($, on)

      world.files[README] = { text: `${FRONTMATTER}\nlast updated now\n`, mtimeMs: START + 5 }
      await $.turn.complete(turnEnd('t1'))
      await world.clock.advance(MINUTE)
      world.files[README] = { text: `${FRONTMATTER}\nlast updated later\n`, mtimeMs: world.clock.now() }
      await $.turn.start({ text: 'a teammate message', turnId: 't2' })
      await $.turn.complete(turnEnd('t2'))
      await world.clock.advance(5 * MINUTE)

      expect(world.seen.commands).toEqual([])
      expect(world.seen.stats, 'the mod does not look at a file time').toBe(0)
      expect(await shown($)).toContain('sequence: waiting for the handoff signal')
    })

    describe('marker file', () => {
      test('the open code in the marker file counts as the call, at the next main turn end', async ($, on) => {
        const world = await atHandoffTurn($, on)

        await $.turn.complete(turnEnd('t1'))
        await $.turn.start({ text: 'a teammate message', turnId: 't2' })
        world.files[MARKER] = { text: `${codeOf(world)}\n`, mtimeMs: world.clock.now() }

        expect(world.seen.commands).toEqual([])

        await $.turn.complete(turnEnd('t2'))

        expect(world.seen.commands, 'inside the dispatch of that turn end').toEqual([ASKED])

        await world.clock.settle()

        expect(world.seen.compacts).toHaveLength(1)
        expect(world.seen.prompts.at(-1)).toStartWith(RESTART)
        expect(logsOf(world)).toContain('handoff signal received (marker file .remember/demo/.handoff)')
      })

      test('the open code in the marker file counts on the timer, with no turn end, also while the handoff turn runs', async ($, on) => {
        const world = await atHandoffTurn($, on)

        world.files[MARKER] = { text: `handoff done ${codeOf(world).toUpperCase()}`, mtimeMs: world.clock.now() }
        await world.clock.advance(16 * 1000)

        expect(world.seen.commands).toEqual([ASKED])
        expect(world.seen.compacts).toHaveLength(1)
        expect(world.seen.prompts.at(-1)).toStartWith(RESTART)
      })

      test('a wrong code and an empty file do nothing, and each is logged once', async ($, on) => {
        const world = await atHandoffTurn($, on)

        world.files[MARKER] = { text: 'zzzz-zzzz', mtimeMs: world.clock.now() }
        await $.turn.complete(turnEnd('t1'))
        await world.clock.advance(MINUTE)
        world.files[MARKER] = { text: '', mtimeMs: world.clock.now() }
        await world.clock.advance(MINUTE)

        expect(world.seen.commands).toEqual([])
        expect(world.seen.reads.filter(path => path === MARKER).length, 'read at the turn end and at each tick').toBeGreaterThan(4)
        expect(world.seen.logs.filter(text => text.includes('.remember/demo/.handoff holds a wrong or an old code: ignored'))).toHaveLength(1)
        expect(world.seen.logs.filter(text => text.includes('.remember/demo/.handoff is empty: ignored'))).toHaveLength(1)
        expect(await shown($)).toContain('sequence: waiting for the handoff signal')
      })

      test('the code of an earlier sequence, left in the file, does not signal the next one', async ($, on) => {
        const world = await atHandoffTurn($, on)
        const first = codeOf(world)

        world.files[MARKER] = { text: first, mtimeMs: world.clock.now() }
        await $.turn.complete(turnEnd('t1'))
        await world.clock.settle()

        expect(world.seen.compacts, 'the first sequence took its own code').toHaveLength(1)

        await $.session.measure(measureAt(30))
        await $.session.measure(measureAt(56))
        await world.clock.settle()

        const second = codeOf(world)

        expect(second).not.toBe(first)
        expect(second).toMatch(/^[a-z2-9]{4}-[a-z2-9]{4}$/)

        await $.turn.start({ text: world.seen.prompts.at(-1) ?? '', turnId: 't5' })
        await $.turn.complete(turnEnd('t5'))
        await world.clock.advance(5 * MINUTE)

        expect(world.seen.commands, 'the stale code asks for nothing').toEqual([ASKED])
        expect(world.seen.compacts).toHaveLength(1)
        expect(world.seen.logs.filter(text => text.includes('holds a wrong or an old code: ignored'))).toHaveLength(1)
        expect(await shown($)).toContain(`code: ${second}`)
      })

      test('what one sequence ignored is logged again for the next sequence', async ($, on) => {
        const world = await atHandoffTurn($, on)

        world.files[MARKER] = { text: 'zzzz-zzzz', mtimeMs: world.clock.now() }
        await $.turn.complete(turnEnd('t1'))
        await world.clock.advance(11 * MINUTE)

        expect(toastsOf(world)).toContain('no handoff signal')

        await $.command.run(orch('handoff'))
        await world.clock.settle()
        await $.turn.start({ text: world.seen.prompts.at(-1) ?? '', turnId: 't5' })
        await $.turn.complete(turnEnd('t5'))
        await world.clock.advance(MINUTE)

        expect(world.seen.logs.filter(text => text.includes('holds a wrong or an old code: ignored'))).toHaveLength(2)
        expect(world.seen.commands).toEqual([])
      })

      test('the tool call and the marker file together compact once', async ($, on) => {
        const world = await atHandoffTurn($, on)
        const code = codeOf(world)

        world.files[MARKER] = { text: code, mtimeMs: world.clock.now() }

        const [answer] = await Promise.all([$.tool.call(done('demo', code)), $.turn.complete(turnEnd('t1'))])

        await world.clock.advance(MINUTE)

        expect(answer.deny === undefined || String(answer.deny).includes('was used already')).toBe(true)
        expect(world.seen.commands).toEqual([ASKED])
        expect(world.seen.compacts).toHaveLength(1)
        expect(world.seen.prompts.filter(text => text.startsWith(RESTART))).toHaveLength(1)
      })

      test('a call that lands while a step reads the marker file with the code: one compaction', async ($, on) => {
        const world = await atHandoffTurn($, on)
        const code = codeOf(world)

        await $.turn.complete(turnEnd('t1'))
        world.files[MARKER] = { text: code, mtimeMs: world.clock.now() }
        world.readMs = 1000
        await world.clock.advance(15 * 1000 + 500)

        expect(world.seen.commands, 'the timer step is in flight on its read of the marker').toEqual([])

        const answer = await $.tool.call(done('demo', code))

        await world.clock.advance(MINUTE)

        expect(String(answer.result)).toContain('accepted')
        expect(world.seen.commands).toEqual([ASKED])
        expect(world.seen.compacts).toHaveLength(1)
        expect(world.seen.prompts.filter(text => text.startsWith(RESTART))).toHaveLength(1)
        expect(world.seen.logs.filter(text => text.includes('handoff signal received'))).toHaveLength(1)
      })

      test('a call that lands while the step at the time limit reads the marker file still compacts', async ($, on) => {
        const world = await atHandoffTurn($, on)
        const code = codeOf(world)

        world.files[MARKER] = { text: 'zzzz-zzzz', mtimeMs: world.clock.now() }
        await $.turn.complete(turnEnd('t1'))
        await world.clock.advance(10 * MINUTE - 5000)
        world.readMs = 20 * 1000

        // The step that starts now ends past the ten minutes.
        await world.clock.advance(15 * 1000)

        const answer = await $.tool.call(done('demo', code))

        await world.clock.advance(MINUTE)

        expect(String(answer.result)).toContain('accepted')
        expect(toastsOf(world), 'the step that ran past the limit does not stop a signaled sequence').not.toContain('stopped')
        expect(world.seen.commands).toEqual([ASKED])
        expect(world.seen.prompts.filter(text => text.startsWith(RESTART))).toHaveLength(1)
      })
    })

    describe('a call in another session', () => {
      const OPEN = { code: 'abcd-efgh', sessionId: 'session-of-the-orchestrator', at: START - 1000 }

      test('the lane session checks the code against the open record, leaves a record and sends the orchestrator a message', async ($, on) => {
        const world = worldOf(on, demo())

        world.store['open/demo'] = OPEN
        await $.session.start(SESSION)

        const answer = await $.tool.call(done('demo', 'ABCD-efgh ', { note: 'written by the scribe' }))

        expect(String(answer.result)).toContain('accepted: relayed to the orchestrator session of demo')
        expect(world.seen.sent).toHaveLength(1)
        expect(world.seen.sent[0]?.to).toContain('session-of-the-orchestrator')
        expect(world.seen.sent[0]?.text).toBe('[orch-handoff-done] slug=demo code=abcd-efgh')
        expect(world.store['done/demo']).toEqual({
          code: 'abcd-efgh',
          at: START,
          note: 'written by the scribe',
          from: SESSION_ID,
        })
        expect(world.seen.commands, 'the lane session compacts nothing of its own').toEqual([])
        expect(world.seen.logs.join('\n')).toContain('handoff_done for demo relayed to session session-of-the-orchestrator: delivered')
      })

      test('a message that is not delivered leaves the record, and the answer says so', async ($, on) => {
        const world = worldOf(on, demo())

        world.store['open/demo'] = OPEN
        world.sendError = 'no live session on this machine has that id'
        await $.session.start(SESSION)

        const answer = await $.tool.call(done('demo', 'abcd-efgh'))

        expect(String(answer.result)).toContain('accepted: recorded for the orchestrator session of demo')
        expect(String(answer.result)).toContain('the direct message was not delivered: no live session on this machine has that id')
        expect(world.store['done/demo']).toBeDefined()
      })

      test('a wrong code, or a project with no open sequence, is refused: no record, no message', async ($, on) => {
        const world = worldOf(on, demo())

        world.store['open/demo'] = OPEN
        await $.session.start(SESSION)

        const wrong = await $.tool.call(done('demo', 'zzzz-zzzz'))
        const none = await $.tool.call(done('nope', 'abcd-efgh'))

        expect(wrong.deny).toContain('wrong code for demo')
        expect(none.deny).toContain('no handoff sequence is open for "nope" on this machine. This session is not bound to a project.')
        expect(world.seen.sent).toEqual([])
        expect(world.store['done/demo']).toBeUndefined()
        expect(world.store['done/nope']).toBeUndefined()
      })

      test('a session bound to another project relays a call for the open one', async ($, on) => {
        const world = await bound($, on)

        world.store['open/other'] = OPEN

        const answer = await $.tool.call(done('other', 'abcd-efgh'))

        await world.clock.advance(MINUTE)

        expect(String(answer.result)).toContain('accepted: relayed to the orchestrator session of other')
        expect(world.seen.sent[0]?.text).toBe('[orch-handoff-done] slug=other code=abcd-efgh')
        expect(world.seen.commands).toEqual([])
      })

      test('the orchestrator takes the message with the open code: it compacts, and the model never reads the message', async ($, on) => {
        const world = await atHandoffTurn($, on)

        await $.turn.complete(turnEnd('t1'))

        const received = await $.session.receive(relayed('demo', codeOf(world)))

        expect(received.consumed).toBe('orch: handoff relay')
        expect(world.seen.commands, 'not inside the delivery').toEqual([])

        await world.clock.settle()

        expect(world.seen.commands).toEqual([ASKED])
        expect(world.seen.compacts).toHaveLength(1)
        expect(world.seen.prompts.at(-1)).toStartWith(RESTART)
        expect(logsOf(world)).toContain('handoff signal received (relay from another session)')
      })

      test('a message with a wrong code, or for another project, is taken and counts for nothing', async ($, on) => {
        const world = await atHandoffTurn($, on)

        const wrong = await $.session.receive(relayed('demo', 'zzzz-zzzz'))
        const other = await $.session.receive(relayed('other', codeOf(world)))

        await world.clock.advance(MINUTE)

        expect(wrong.consumed).toBe('orch: handoff relay')
        expect(other.consumed).toBe('orch: handoff relay')
        expect(world.seen.commands).toEqual([])
        expect(logsOf(world)).toContain('a handoff relay for demo did not count (wrong)')
        expect(logsOf(world)).toContain('a handoff relay for other came here; this session is bound to demo: ignored')
      })

      test('any other delivery, and one for a subagent, passes as it came', async ($, on) => {
        const world = await atHandoffTurn($, on)
        const plain = await $.session.receive({ origin: { kind: 'peer' }, text: 'a message from a lane' })
        const forAgent = await $.session.receive({ ...relayed('demo', codeOf(world)), agentId: 'a1' })

        await world.clock.advance(MINUTE)

        expect(plain.text).toBe('a message from a lane')
        expect(forAgent.consumed).toBeUndefined()
        expect(world.seen.commands).toEqual([])
      })

      test('the record a lane session left counts at the next tick, with no message and no turn end', async ($, on) => {
        const world = await atHandoffTurn($, on)

        await $.turn.complete(turnEnd('t1'))
        world.store['done/demo'] = { code: codeOf(world), at: world.clock.now(), note: '', from: 'session-of-a-lane' }
        await world.clock.advance(16 * 1000)

        expect(world.seen.commands).toEqual([ASKED])
        expect(world.seen.prompts.at(-1)).toStartWith(RESTART)
        expect(logsOf(world)).toContain('handoff signal received (relay record from session session-of-a-lane)')
        expect(world.store['done/demo'], 'removed when the sequence ended').toBeUndefined()
      })

      test('a record with an old code counts for nothing and is logged once', async ($, on) => {
        const world = await atHandoffTurn($, on)

        world.store['done/demo'] = { code: 'zzzz-zzzz', at: world.clock.now(), note: '', from: 'session-of-a-lane' }
        await $.turn.complete(turnEnd('t1'))
        await world.clock.advance(2 * MINUTE)

        expect(world.seen.commands).toEqual([])
        expect(world.seen.logs.filter(text => text.includes('the relay record of demo holds a wrong or an old code: ignored'))).toHaveLength(1)
      })
    })

    describe('/orch done', () => {
      test('ends the wait by hand: /compact, then the restart prompt', async ($, on) => {
        const world = await atHandoffTurn($, on)

        await $.turn.complete(turnEnd('t1'))

        const ran = await $.command.run(orch('done'))

        expect(ran.text).toContain('handoff marked as written by hand for demo')

        await world.clock.settle()

        expect(world.seen.commands).toEqual([ASKED])
        expect(world.seen.compacts).toHaveLength(1)
        expect(world.seen.prompts.at(-1)).toStartWith(RESTART)
        expect(logsOf(world)).toContain('handoff signal received (the person, /orch done)')
        expect((await $.command.run(orch('done'))).text).toContain('no handoff sequence is open (last sequence: compacted')
      })

      test('with the signal in already, with no sequence, and unbound, it starts nothing', async ($, on) => {
        const world = await atHandoffTurn($, on)

        world.queueMs = MINUTE
        await $.tool.call(done('demo', codeOf(world)))
        await world.clock.settle()

        expect((await $.command.run(orch('done'))).text).toContain('the handoff signal is in already (tool handoff_done); /compact is in the queue')

        await world.clock.advance(MINUTE)

        expect(world.seen.commands).toEqual([ASKED])

        await $.command.run(orch('off'))

        expect((await $.command.run(orch('done'))).text).toContain('not bound')
      })
    })

    // webd session 26211431, 23:16:50Z: "a turn is running" six times in a row.
    // Live, 2.1.287: in a bound session with a prompt in the queue the engine
    // refuses `$.session.compact` at each turn end, and runs a /compact command
    // in its place in the queue.
    test('a busy session: /compact is asked for once and waits in the queue, whatever ends or ticks meanwhile', async ($, on) => {
      const world = await atHandoffTurn($, on)

      world.queueMs = 3 * MINUTE
      await $.tool.call(done('demo', codeOf(world)))
      await world.clock.settle()
      await $.turn.complete(turnEnd('t1'))

      expect(world.seen.commands).toEqual([ASKED])
      expect(world.seen.compacts, 'in the queue: nothing compacts yet').toEqual([])
      expect(await shown($)).toContain('sequence: handoff signaled (tool handoff_done); /compact is in the queue (asked 0 s ago')

      for (const turn of ['t2', 't3', 't4']) {
        await $.turn.start({ text: 'a teammate message', turnId: turn })
        await world.clock.advance(50 * 1000)
        await $.turn.complete(turnEnd(turn))
      }

      expect(world.seen.commands, 'three turn ends and the timer later: never asked for twice').toEqual([ASKED])
      expect(world.seen.compacts).toEqual([])
      expect(toastsOf(world)).not.toContain('stopped')

      await world.clock.advance(MINUTE)

      expect(world.seen.compacts).toHaveLength(1)
      expect(world.seen.prompts.filter(text => text.startsWith(RESTART))).toHaveLength(1)
      expect(logsOf(world)).toContain('sequence ended: compacted (900 to 100 tokens)')
    })

    test('a /compact that does not come to the front of the queue in thirty minutes ends the sequence with a toast and a log line', async ($, on) => {
      const world = await atHandoffTurn($, on)

      world.queueMs = 600 * MINUTE
      await $.tool.call(done('demo', codeOf(world)))
      await world.clock.advance(29 * MINUTE)

      expect(toastsOf(world), 'inside the thirty minutes the sequence stays open').not.toContain('stopped')

      await world.clock.advance(2 * MINUTE)

      expect(toastsOf(world)).toContain(
        'handoff sequence stopped: no compaction: /compact did not run in 30 minutes after it was asked for. Run /compact.',
      )
      expect(logsOf(world)).toContain('sequence ended: no compaction: /compact did not run in 30 minutes')
      expect(world.seen.commands).toEqual([ASKED])
      expect(world.seen.prompts).toHaveLength(1)
      expect(await shown($)).toContain('last sequence: no compaction: /compact did not run')
    })

    test('a /compact that runs and compacts nothing ends the sequence with the reason and no restart prompt', async ($, on) => {
      const world = await atHandoffTurn($, on)

      world.runCompact = undefined
      await $.tool.call(done('demo', codeOf(world)))
      await world.clock.advance(MINUTE)

      expect(world.seen.commands).toEqual([ASKED])
      expect(toastsOf(world)).toContain('handoff sequence stopped: no compaction: /compact ran and did not compact. Run /compact.')
      expect(logsOf(world)).toContain('sequence ended: no compaction: /compact ran and did not compact')
      expect(world.seen.prompts).toHaveLength(1)
    })

    test('a /compact that a hook vetoes ends the sequence with the reason', async ($, on) => {
      const world = await atHandoffTurn($, on)

      world.skipCompact = 'a settings hook blocked it'
      await $.tool.call(done('demo', codeOf(world)))
      await world.clock.advance(MINUTE)

      expect(world.seen.commands, 'asked once, not at each tick').toEqual([ASKED])
      expect(toastsOf(world)).toContain('handoff sequence stopped: no compaction: skipped: a settings hook blocked it. Run /compact.')
      expect(logsOf(world)).toContain('sequence ended: no compaction: skipped: a settings hook blocked it')
      expect(world.seen.prompts).toHaveLength(1)
    })

    test('a /compact command that fails ends the sequence with the reason', async ($, on) => {
      const world = await atHandoffTurn($, on)

      world.commandError = 'no such command'
      await $.tool.call(done('demo', codeOf(world)))
      await world.clock.advance(MINUTE)

      expect(toastsOf(world), 'the call was refused').toMatch(/handoff sequence stopped: no compaction: \/compact failed: .+\. Run \/compact\./)
      expect(logsOf(world)).toContain('sequence ended: no compaction: /compact failed:')
      expect(world.seen.prompts).toHaveLength(1)
    })

    test('the end of another turn, or of a subagent run with the same id, leaves the handoff turn running', async ($, on) => {
      const world = await atHandoffTurn($, on)

      await $.turn.complete(turnEnd('t0'))
      await $.turn.complete(turnEnd('t1', { agentId: 'a1' }))
      await world.clock.advance(600)

      expect(world.seen.commands).toEqual([])
      expect(await shown($)).toContain('sequence: the handoff turn is running')

      await $.turn.complete(turnEnd('t1'))

      expect(await shown($)).toContain('sequence: waiting for the handoff signal')
    })

    test('a turn that starts with other words is not the handoff turn', async ($, on) => {
      const world = await bound($, on)

      await $.session.measure(measureAt(56))
      await world.clock.settle()
      await $.turn.start({ text: 'a prompt the person queued', turnId: 't0' })
      await $.turn.complete(turnEnd('t0'))
      await world.clock.advance(600)

      expect(world.seen.commands).toEqual([])
      expect(await shown($)).toContain('sequence: handoff prompt sent')
    })

    test('a turn that carries the handoff words outside a sequence starts nothing', async ($, on) => {
      const world = await bound($, on)

      await $.turn.start({ text: `${HANDOFF}: pasted by the person`, turnId: 't9' })
      await $.turn.complete(turnEnd('t9'))
      await world.clock.advance(600)

      expect(world.seen.commands).toEqual([])
      expect(world.seen.prompts).toEqual([])
      expect(await shown($)).toContain('sequence: idle')
    })

    test('an interrupted handoff turn asks for nothing, and says so in a toast and in the log', async ($, on) => {
      const world = await atHandoffTurn($, on)

      await $.turn.complete(turnEnd('t1', { reason: 'aborted', isAborted: true }))
      await world.clock.advance(MINUTE)

      expect(world.seen.commands).toEqual([])
      expect(toastsOf(world)).toContain('handoff sequence stopped: the handoff turn ended (aborted). No compaction.')
      expect(logsOf(world)).toContain('sequence ended: the handoff turn ended (aborted)')
    })

    test("the person's /compact while the sequence waits for the signal ends the sequence: no second compaction, no restart prompt", async ($, on) => {
      const world = await atHandoffTurn($, on)
      const code = codeOf(world)

      await $.turn.complete(turnEnd('t1'))
      await $.session.compact(compaction({}))

      expect(toastsOf(world)).toContain('handoff sequence stopped: the person compacted in phase waiting. Check .remember/demo/README.md.')
      expect(logsOf(world)).toContain('sequence ended: the person compacted in phase waiting')

      const late = await $.tool.call(done('demo', code))

      await world.clock.advance(MINUTE)

      expect(late.deny).toContain('no handoff sequence is open for demo (last sequence: the person compacted in phase waiting)')
      expect(world.seen.commands).toEqual([])
      expect(world.seen.compacts, "the person's alone").toHaveLength(1)
      expect(world.seen.prompts).toHaveLength(1)
    })

    test("the person's /compact while the mod's own waits in the queue leaves the sequence open: the own one still runs", async ($, on) => {
      const world = await atHandoffTurn($, on)

      world.queueMs = MINUTE
      await $.tool.call(done('demo', codeOf(world)))
      await world.clock.settle()
      await $.session.compact(compaction({ instructions: 'keep the plan' }))
      await world.clock.settle()

      expect(toastsOf(world)).not.toContain('stopped')
      expect(world.seen.prompts, 'no restart prompt for a compaction of the person').toHaveLength(1)
      expect(await shown($)).toContain('/compact is in the queue')

      await world.clock.advance(MINUTE)

      expect(world.seen.compacts, "the person's, then the sequence's").toHaveLength(2)
      expect(world.seen.prompts.at(-1)).toStartWith(RESTART)
    })

    test('a compaction the engine computes ahead of time is not the run of the /compact in the queue', async ($, on) => {
      const world = await atHandoffTurn($, on)

      world.queueMs = MINUTE
      await $.tool.call(done('demo', codeOf(world)))
      await world.clock.settle()
      await $.session.compact(compaction({ trigger: 'precompute', instructions: OWN }))
      await world.clock.settle()

      expect(world.seen.prompts, 'no restart prompt: nothing was compacted').toHaveLength(1)
      expect(await shown($)).toContain('/compact is in the queue')

      await world.clock.advance(MINUTE)

      expect(world.seen.prompts.at(-1)).toStartWith(RESTART)
    })

    test("the person's /compact while the handoff turn runs leaves the sequence open", async ($, on) => {
      const world = await atHandoffTurn($, on)

      await $.session.compact(compaction({}))

      expect(toastsOf(world)).not.toContain('stopped')

      await $.tool.call(done('demo', codeOf(world)))
      await world.clock.settle()

      expect(world.seen.compacts, "the person's, then the sequence's").toHaveLength(2)
    })

    test('an engine compaction while the sequence waits for the signal ends the sequence', async ($, on) => {
      const world = await atHandoffTurn($, on)

      await $.turn.complete(turnEnd('t1'))
      await $.session.compact(compaction({ trigger: 'auto' }))

      expect(toastsOf(world)).toContain('handoff sequence stopped: the engine compacted in phase waiting.')
    })

    test('/orch off while a sequence is open stops it and says so', async ($, on) => {
      const world = await atHandoffTurn($, on)
      const code = codeOf(world)

      await $.turn.complete(turnEnd('t1'))
      await $.command.run(orch('off'))

      expect(toastsOf(world)).toContain('handoff sequence stopped: unbound in phase waiting. No compaction.')
      expect(logsOf(world)).toContain('sequence ended: unbound in phase waiting')
      expect(world.store['open/demo'], 'the open record goes with the sequence').toBeUndefined()

      await $.command.run(orch('demo'))

      expect(await shown($), 'a bind keeps how the last sequence ended').toContain('last sequence: unbound in phase waiting')

      world.files[MARKER] = { text: code, mtimeMs: world.clock.now() }
      await world.clock.advance(MINUTE)

      expect(world.seen.commands).toEqual([])
    })

    test('a load of the module in the middle of a sequence continues it from the stored state, with the same code', async ($, on) => {
      const world = await atHandoffTurn($, on)
      const code = codeOf(world)

      await $.turn.complete(turnEnd('t1'))
      await $.session.start(SESSION)

      expect(logsOf(world)).toContain('sequence open at the start of this load (waiting); continuing')
      expect(await shown($)).toContain(`code: ${code}`)

      await $.tool.call(done('demo', code))
      await world.clock.settle()

      expect(world.seen.commands).toEqual([ASKED])
      expect(world.seen.prompts.at(-1)).toStartWith(RESTART)
    })

    test('in a headless session the call in the handoff turn asks for /compact once, and the restart prompt follows', async ($, on) => {
      const world = await atHandoffTurn($, on, HEADLESS)

      await $.tool.call(done('demo', codeOf(world)))

      expect(world.seen.commands, 'not inside the tool call').toEqual([])

      await world.clock.settle()
      await $.turn.complete(turnEnd('t1'))
      await world.clock.advance(600)

      expect(world.seen.commands).toEqual([ASKED])
      expect(world.seen.compacts).toHaveLength(1)
      expect(world.seen.compacts[0]?.instructions).toBe(ASKED)
      expect(world.seen.prompts.at(-1)).toStartWith(RESTART)
      expect(toastsOf(world), 'its own /compact is not the person compacting').not.toContain('stopped')
    })

    test('in a headless session the marker file is read after the turn end, not inside it', async ($, on) => {
      const world = await atHandoffTurn($, on, HEADLESS)

      world.files[MARKER] = { text: codeOf(world), mtimeMs: world.clock.now() }
      await $.turn.complete(turnEnd('t1'))

      expect(world.seen.commands, 'not inside the turn end').toEqual([])

      await world.clock.advance(600)

      expect(world.seen.commands).toEqual([ASKED])
      expect(world.seen.prompts.at(-1)).toStartWith(RESTART)
    })

    test('after one sequence the limit starts no other until the fill drops below the warning level', async ($, on) => {
      const world = await atHandoffTurn($, on)

      await $.turn.complete(turnEnd('t1'))
      await world.clock.advance(11 * MINUTE)
      await $.session.measure(measureAt(57))
      await $.session.measure(measureAt(58))
      await world.clock.settle()

      expect(world.seen.prompts).toHaveLength(1)
      expect(world.seen.toasts.filter(text => text.includes('No new sequence'))).toHaveLength(1)

      await $.session.measure(measureAt(50))
      await $.session.measure(measureAt(56))
      await world.clock.settle()

      expect(world.seen.prompts, 'between the warning level and the limit is not a drop').toHaveLength(1)

      await $.session.measure(measureAt(30))
      await $.session.measure(measureAt(56))
      await world.clock.settle()

      expect(world.seen.prompts).toHaveLength(2)
    })

    test('a sequence that never reaches its turn times out with a toast and a log line', async ($, on) => {
      const world = await bound($, on)

      await $.session.measure(measureAt(56))
      await world.clock.settle()
      await world.clock.advance(29 * MINUTE)

      expect(toastsOf(world)).not.toContain('timed out')

      await world.clock.advance(2 * MINUTE)

      expect(toastsOf(world)).toContain('handoff sequence stopped: timed out: the handoff turn did not start in 30 minutes. Run /orch handoff.')
      expect(logsOf(world)).toContain('sequence ended: timed out')
      expect((await $.command.run(orch('handoff'))).text).toContain('handoff requested')
    })

    test('a handoff prompt that does not enter ends the sequence with a toast and a log line', async ($, on) => {
      const world = await bound($, on)

      world.dropPrompt = 'a settings hook blocked the prompt'
      await $.session.measure(measureAt(56))
      await world.clock.settle()

      expect(toastsOf(world)).toContain('handoff sequence stopped: the handoff prompt did not enter: a settings hook blocked the prompt. Run /orch handoff.')
      expect(logsOf(world)).toContain('sequence ended: the handoff prompt did not enter')
      expect(world.store['open/demo']).toBeUndefined()
    })
  })

  describe('the tool', () => {
    test('every session registers handoff_done, bound or not, in the list of tools', async ($, on) => {
      const world = worldOf(on, demo())

      await $.session.start(SESSION)

      expect(world.seen.tools).toEqual([TOOL])

      const described = await $.tool.describe({
        tool: TOOL,
        description: 'as registered',
        isDeferred: true,
        provider: { plugin: 'orch', tier: 'user' },
      })

      expect(described.isDeferred, 'in the list: a lane calls it by the name the request gives').toBe(false)
      expect(described.description).toBe('as registered')
      expect((await $.tool.describe({ tool: 'Bash', description: 'x', isDeferred: true, provider: { plugin: 'engine', tier: 'core' } })).isDeferred, 'no other tool is moved').not.toBe(false)
    })

    test('the bind text and the role name the tool', async ($, on) => {
      const world = worldOf(on, demo())

      await $.session.start(SESSION)

      const ran = await $.command.run(orch('demo'))

      expect(ran.text).toContain(`handoff signal: the tool ${TOOL} with the code of the handoff request (backup: the code in .remember/demo/.handoff, or /orch done)`)
      expect(await roleOf($)).toContain('call the tool `mcp__orch__handoff_done` with the slug and the code from that request')
      expect(world.seen.prompts).toEqual([])
    })
  })

  describe('state from before a reload', () => {
    const MINUTE = 60 * 1000
    const BOUND: OrchBinding = {
      slug: 'demo',
      readme: README,
      readmeRel: '.remember/demo/README.md',
      root: '.remember',
      goal: 'Move the API and the CLI from Python to Go',
      linearProject: 'Dev Health Ops',
      canonical: [],
      role: '',
      hasFrontmatter: true,
      lines: 13,
    }

    /** The session's state as a module loaded earlier left it: read on the first get of this load. */
    function stored(on: On, sequence: Partial<OrchSequence>) {
      on('state.get', (_engine, e, next) => {
        if (e.plugin === 'orch' && e.key === 'binding') {
          return { value: { value: BOUND, version: 1 } }
        }

        if (e.plugin === 'orch' && e.key === 'sequence') {
          return { value: { value: sequence, version: 1 } }
        }

        return next(e)
      })
    }

    function worldWith($: Engine, on: On, files = demo()) {
      const world = worldOf(on, files)

      world.runCompact = args => $.session.compact(compaction({ instructions: args }))

      return world
    }

    test('a sequence with a code that a load of the module finds waiting takes the call', async ($, on) => {
      const world = worldWith($, on)

      stored(on, { phase: 'waiting', startedAt: START - 60_000, phaseAt: START - 30_000, turnId: 't1', code: 'abcd-efgh', isArmed: false })
      await $.session.start(SESSION)

      expect(world.seen.logs.join('\n')).toContain('sequence open at the start of this load (waiting); continuing')

      await $.tool.call(done('demo', 'abcd-efgh'))
      await world.clock.settle()

      expect(world.seen.commands).toEqual([ASKED])
      expect(world.seen.prompts).toEqual([expect.stringContaining(RESTART)])
    })

    test('a sequence that waits for its signal across a load still stops at its time limit', async ($, on) => {
      const world = worldWith($, on)

      stored(on, { phase: 'waiting', startedAt: START - 9 * MINUTE, phaseAt: START - 9 * MINUTE, turnId: 't1', code: 'abcd-efgh', isArmed: false })
      await $.session.start(SESSION)
      await world.clock.advance(30 * 1000)

      expect(world.seen.toasts.join('\n')).not.toContain('stopped')

      await world.clock.advance(MINUTE)

      expect(world.seen.toasts.join('\n')).toContain('no handoff signal: handoff_done was not called with code abcd-efgh in 10 minutes')
      expect(world.seen.commands).toEqual([])
    })

    // 0.2 waited for the README to change and gave no code.
    test('a sequence the version before this one left waiting has no code: it stops at the load and says so', async ($, on) => {
      const world = worldWith($, on)

      stored(on, { phase: 'waiting', startedAt: START - 1000, turnId: 't1', isArmed: false, hasWarned: true, hasNagged: false })
      await $.session.start(SESSION)
      world.files[README] = { text: FRONTMATTER, mtimeMs: world.clock.now() }
      await world.clock.advance(MINUTE)

      expect(world.seen.toasts.join('\n')).toContain(
        'handoff sequence stopped: the sequence was started by an older version of the mod and has no code (phase waiting). Run /orch handoff.',
      )
      expect(world.seen.commands).toEqual([])
      expect((await $.command.run(orch('handoff'))).text).toContain('handoff requested for demo')
    })

    test('a sequence left in phase compacting with /compact not asked for asks for it with no turn end', async ($, on) => {
      const world = worldWith($, on)

      stored(on, { phase: 'compacting', startedAt: START - 1000, turnId: 't1', isArmed: false, hasWarned: true, hasNagged: false })
      await $.session.start(SESSION)

      expect((await $.command.run(orch(''))).text).toContain('/compact is not asked for yet')

      await world.clock.advance(1000)

      expect(world.seen.toasts.join('\n')).not.toContain('stopped')
      expect(world.seen.commands).toEqual([ASKED])
      expect(world.seen.prompts).toEqual([expect.stringContaining(RESTART)])
    })

    test('a /compact asked for before a reload is not asked for again; when it runs, the sequence ends with the restart prompt', async ($, on) => {
      const world = worldWith($, on)

      stored(on, { ...{ phase: 'compacting', startedAt: START - 60_000, turnId: 't1', phaseAt: START - 30_000 }, askedAt: START - 30_000 })
      await $.session.start(SESSION)
      await world.clock.advance(5 * MINUTE)

      expect(world.seen.commands, 'the command of the module before the reload is in the queue').toEqual([])
      expect((await $.command.run(orch(''))).text).toContain('/compact is in the queue')

      await $.session.compact(compaction({ instructions: OWN }))
      await world.clock.settle()

      expect(world.seen.compacts).toHaveLength(1)
      expect(world.seen.prompts).toEqual([expect.stringContaining(RESTART)])
      expect(world.seen.logs.join('\n')).toContain('sequence ended: compacted (900 to 100 tokens)')
    })

    test('a /compact asked for before a reload that a hook vetoes ends the sequence with the reason', async ($, on) => {
      const world = worldWith($, on)

      stored(on, { ...{ phase: 'compacting', startedAt: START - 60_000, turnId: 't1', phaseAt: START - 30_000 }, askedAt: START - 30_000 })
      world.skipCompact = 'a settings hook blocked it'
      await $.session.start(SESSION)
      await $.session.compact(compaction({ instructions: OWN }))
      await world.clock.settle()

      expect(world.seen.toasts.join('\n')).toContain('handoff sequence stopped: no compaction: skipped: a settings hook blocked it. Run /compact.')
      expect(world.seen.prompts).toEqual([])
    })

    test('a /compact asked for before a reload that never runs ends the sequence thirty minutes after it was asked for', async ($, on) => {
      const world = worldWith($, on)

      stored(on, { ...{ phase: 'compacting', startedAt: START - 60_000, turnId: 't1', phaseAt: START - 30_000 }, askedAt: START - 30_000 })
      await $.session.start(SESSION)
      await world.clock.advance(29 * MINUTE)

      expect(world.seen.toasts.join('\n')).not.toContain('stopped')

      await world.clock.advance(2 * MINUTE)

      expect(world.seen.toasts.join('\n')).toContain('no compaction: /compact did not run in 30 minutes after it was asked for')
      expect(world.seen.commands).toEqual([])
    })
  })

  describe('compaction', () => {
    test("the person's /compact carries the project line ahead of the typed instructions", async ($, on) => {
      const world = await bound($, on)

      await $.session.compact(compaction({ instructions: 'keep the plan' }))

      expect(world.seen.compacts[0]?.instructions).toBe(
        'Orchestrator for demo: Move the API and the CLI from Python to Go. Keep: open lanes, pending decisions, in-flight PRs and tickets, restart steps. Entry point .remember/demo/README.md.\n\nkeep the plan',
      )
      expect(world.seen.prompts, 'no restart prompt after a compaction the person ran').toEqual([])
    })

    test('a bare /compact carries the project line alone', async ($, on) => {
      const world = await bound($, on)

      await $.session.compact(compaction({}))

      expect(world.seen.compacts[0]?.instructions).toStartWith('Orchestrator for demo:')
      expect(world.seen.compacts[0]?.instructions).toEndWith('Entry point .remember/demo/README.md.')
    })

    test("a subagent's own compaction is left as it is", async ($, on) => {
      const world = await bound($, on)

      await $.session.compact(compaction({ trigger: 'auto', agentId: 'a1' }))

      expect(world.seen.compacts[0]?.instructions).toBeUndefined()
      await world.clock.settle()
      expect(world.seen.toasts).toEqual([])
    })

    test("the person's /compact with the pickup line binds an unbound session", async ($, on) => {
      const world = worldOf(on, demo())

      await $.session.start(SESSION)
      await $.session.compact(compaction({ instructions: PICKUP }))

      expect(world.seen.compacts[0]?.instructions).toStartWith('Orchestrator for demo:')
      expect(world.seen.compacts[0]?.instructions).toEndWith(PICKUP)
      expect(await roleOf($)).toBeDefined()
    })

    test('an engine compaction binds nothing, whatever its instructions say', async ($, on) => {
      const world = worldOf(on, demo())

      await $.session.start(SESSION)
      await $.session.compact(compaction({ trigger: 'auto', instructions: PICKUP }))

      expect(world.seen.compacts[0]?.instructions).toBe(PICKUP)
      expect(await roleOf($)).toBeUndefined()
    })

    test('an engine compaction with no handoff signal before it is never skipped, says so to the summary and leaves a notice', async ($, on) => {
      const world = await bound($, on)

      // A README that changed a minute ago is no signal.
      world.files[README] = { text: FRONTMATTER, mtimeMs: START - 60 * 1000 }

      const compacted = await $.session.compact(compaction({ trigger: 'auto' }))
      await world.clock.settle()

      expect(compacted.skip).toBeUndefined()
      expect(world.seen.compacts[0]?.instructions).toContain('No handoff was signaled before this compaction')
      expect(world.seen.logs.filter(text => text.includes('compacted with no handoff signal before it'))).toHaveLength(1)
      expect(world.seen.toasts.filter(text => text.includes('compacted with no handoff signal before it'))).toHaveLength(1)
    })

    test('a compaction computed ahead of time carries the same instructions and leaves no notice', async ($, on) => {
      const world = await bound($, on)

      await $.session.compact(compaction({ trigger: 'precompute' }))
      await world.clock.settle()

      expect(world.seen.compacts[0]?.instructions).toStartWith('Orchestrator for demo:')
      expect(world.seen.compacts[0]?.instructions).toContain('No handoff was signaled before this compaction')
      expect(world.seen.toasts).toEqual([])
    })

    test("another plugin's compaction is left as it is", async ($, on) => {
      const world = await bound($, on)

      await $.session.compact(compaction({ trigger: 'plugin', instructions: 'theirs' }))
      await world.clock.settle()

      expect(world.seen.compacts[0]?.instructions).toBe('theirs')
      expect(world.seen.toasts).toEqual([])
    })

    test('an engine compaction that is skipped leaves no notice', async ($, on) => {
      const world = await bound($, on)

      world.skipCompact = 'a settings hook blocked it'
      const compacted = await $.session.compact(compaction({ trigger: 'auto' }))
      await world.clock.settle()

      expect(compacted.skip).toBe('a settings hook blocked it')
      expect(world.seen.toasts).toEqual([])
    })

    test('an engine compaction soon after a signaled handoff compacted leaves no notice; ten minutes later it does', async ($, on) => {
      const world = await atHandoffTurn($, on)

      await $.tool.call(done('demo', codeOf(world)))
      await world.clock.settle()
      await $.turn.complete(turnEnd('t1'))
      await world.clock.advance(60 * 1000)
      await $.session.compact(compaction({ trigger: 'auto' }))
      await world.clock.settle()

      expect(world.seen.compacts.at(-1)?.instructions).not.toContain('No handoff was signaled')
      expect(world.seen.toasts.join('\n')).not.toContain('no handoff signal before it')

      await world.clock.advance(10 * 60 * 1000)
      await $.session.compact(compaction({ trigger: 'auto' }))
      await world.clock.settle()

      expect(world.seen.compacts.at(-1)?.instructions).toContain('No handoff was signaled')
    })

    test('an engine compaction while the signal is in and /compact waits in the queue leaves no notice', async ($, on) => {
      const world = await atHandoffTurn($, on)

      world.queueMs = 60 * 1000
      await $.tool.call(done('demo', codeOf(world)))
      await world.clock.settle()
      await $.session.compact(compaction({ trigger: 'auto' }))
      await world.clock.settle()

      expect(world.seen.compacts.at(-1)?.instructions).not.toContain('No handoff was signaled')
      expect(world.seen.toasts.join('\n')).not.toContain('no handoff signal before it')
    })
  })
})
