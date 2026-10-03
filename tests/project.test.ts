import { describe, expect, test } from 'claude-code/testing'

import { GOAL_TODO, isNewSlug, isSlug, parseProject, scaffoldOf, slugsIn } from '../hooks/project'
import { fillRole } from '../hooks/role'
import { FRONTMATTER } from './fixtures/world'

describe('project', () => {
  test('frontmatter gives goal, linear project, canonical list and role', () => {
    expect(parseProject(FRONTMATTER, 'demo')).toEqual({
      goal: 'Move the API and the CLI from Python to Go',
      linearProject: 'Dev Health Ops',
      canonical: [
        'Linear document "Go cutover TRD" is the plan of record',
        'ops/AGENTS.md for the backend rules',
      ],
      role: 'Keep the merge train moving.\nOne lane for each PR.',
      hasFrontmatter: true,
      lines: 13,
    })
  })

  test('an inline list and a folded block parse', () => {
    const text = '---\ncanonical: [a doc, "b doc"]\ngoal: >\n  first\n  second\n---\n# T\n'

    expect(parseProject(text, 'demo')).toMatchObject({
      canonical: ['a doc', 'b doc'],
      goal: 'first second',
    })
  })

  test('with no frontmatter the first heading is the goal', () => {
    expect(parseProject('\nintro\n# Hosted acr-mcp: single entry point\n\n## More\n', 'acr-mcp')).toEqual({
      goal: 'Hosted acr-mcp: single entry point',
      linearProject: '',
      canonical: [],
      role: '',
      hasFrontmatter: false,
      lines: 5,
    })
  })

  test('with no frontmatter and no heading the slug is the goal', () => {
    expect(parseProject('plain text', 'demo').goal).toBe('demo')
  })

  test('frontmatter that never closes is not frontmatter', () => {
    expect(parseProject('---\ngoal: x\n# Title\n', 'demo')).toMatchObject({
      goal: 'Title',
      hasFrontmatter: false,
    })
  })

  test('slugs are read from README paths under the root only', () => {
    const text = 'see @.remember/acr-mcp/README.md and .remember/acr-mcp/README.md, not docs/x/README.md'

    expect(slugsIn(text, '.remember')).toEqual(['acr-mcp'])
    expect(slugsIn('a .remember/a/README.md b .remember/b/README.md', '.remember')).toEqual(['a', 'b'])
    expect(slugsIn('.remember/../README.md', '.remember')).toEqual([])
    expect(slugsIn('xremember/a/README.md', '.remember')).toEqual([])
  })

  test('a slug is one path part', () => {
    expect(isSlug('go-worker-migration')).toBe(true)
    expect(isSlug('..')).toBe(false)
    expect(isSlug('a/b')).toBe(false)
    expect(isSlug('')).toBe(false)
  })

  test('a new project README reads back as the goal typed, whatever the goal holds', () => {
    const goal = 'Ship "v2": fast # not a comment, [a, b] | > \\ done'
    const text = scaffoldOf('demo2', goal, '2026-10-01T00:00:00.000Z')

    expect(parseProject(text, 'demo2')).toEqual({
      goal,
      linearProject: '',
      canonical: [],
      role: '',
      hasFrontmatter: true,
      lines: 25,
    })
    expect(text).toContain('\n# demo2\n\nlast updated: 2026-10-01T00:00:00.000Z\n')

    for (const heading of ['## State', '## Open lanes', '## Pending decisions', '## Restart steps', '## Pointers']) {
      expect(text).toContain(`\n${heading}\n`)
    }

    for (const folder of ['`lanes/`', '`briefs/`', '`docs/`']) {
      expect(text.slice(text.indexOf('## Pointers'))).toContain(folder)
    }
  })

  test('a new project README with no goal holds a visible TODO', () => {
    const text = scaffoldOf('demo2', '', '2026-10-01T00:00:00.000Z')

    expect(text).toContain(`goal: "${GOAL_TODO}"`)
    expect(parseProject(text, 'demo2').goal).toBe(GOAL_TODO)
  })

  test('a quoted value that is not a JSON string keeps the text between its quotes', () => {
    expect(parseProject('---\ngoal: "a \\q b"\n---\n', 'demo').goal).toBe('a \\q b')
  })

  test('a name for a new project is lowercase letters, digits and dashes, and no command word', () => {
    for (const name of ['demo2', 'go-worker-migration', '2fast', 'a']) {
      expect(isNewSlug(name), name).toBe(true)
    }

    for (const name of ['', 'Demo', 'a.b', 'a/b', '..', '-x', 'a_b', 'a b', 'new', 'off', 'handoff', 'done']) {
      expect(isNewSlug(name), name).toBe(false)
    }
  })

  test('the role text holds each value once and leaves a value that looks like a name', () => {
    const text = fillRole({
      slug: 'demo',
      goal: 'ship {limit} things',
      readme: '.remember/demo/README.md',
      dir: '.remember/demo',
      root: '.remember',
      linear_project: 'Dev Health Ops',
      canonical: ['doc A', 'doc B'],
      limit: 55,
      role: 'Extra rule.',
    })

    expect(text).toContain('orchestrator for project `demo`: ship {limit} things')
    expect(text).toContain('Entry point: `.remember/demo/README.md`')
    expect(text).toContain('(project: Dev Health Ops)')
    expect(text).toContain('- doc A\n- doc B')
    expect(text).toContain('stay below 55% context')
    expect(text).toEndWith('Extra rule.')
    expect(text).not.toMatch(/\{[a-z_]+\}(?<!\{limit\})/)
  })
})
