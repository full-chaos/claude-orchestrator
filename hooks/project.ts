export type Project = {
  goal: string
  linearProject: string
  canonical: string[]
  role: string
  hasFrontmatter: boolean
  lines: number
}

export const FRONTMATTER_KEYS = ['goal', 'linear_project', 'canonical', 'role'] as const

function unquote(value: string): string {
  const text = value.trim()
  const first = text[0]
  const isQuoted = text.length >= 2 && (first === '"' || first === "'") && text.endsWith(first)

  if (!isQuoted) {
    return text
  }

  if (first === '"') {
    try {
      const parsed: unknown = JSON.parse(text)

      if (typeof parsed === 'string') {
        return parsed
      }
    } catch {
      // not a JSON string: the text between the quotes stands as written
    }
  }

  return text.slice(1, -1)
}

function inlineList(value: string): string[] {
  return value
    .slice(1, -1)
    .split(',')
    .map(unquote)
    .filter(item => item !== '')
}

/**
 * Reads the README's frontmatter by hand: single-line values, `|` and `>`
 * blocks, `- item` lists and `[a, b]` lists. No other YAML.
 */
function frontmatterOf(lines: readonly string[]): Record<string, string | string[]> | null {
  if (lines[0]?.replace(/^﻿/, '').trim() !== '---') {
    return null
  }

  const end = lines.findIndex((line, index) => index > 0 && /^(---|\.\.\.)\s*$/.test(line))

  if (end === -1) {
    return null
  }

  const found: Record<string, string | string[]> = {}
  let index = 1

  while (index < end) {
    const match = /^([A-Za-z_][\w-]*):\s*(.*)$/.exec(lines[index] ?? '')
    index += 1

    if (match === null) {
      continue
    }

    const key = match[1] ?? ''
    const value = (match[2] ?? '').trim()
    const below: string[] = []

    while (index < end && /^(\s+\S|\s*$)/.test(lines[index] ?? '')) {
      below.push(lines[index] ?? '')
      index += 1
    }

    if (/^[|>][+-]?$/.test(value)) {
      const body = below.map(line => line.trim())
      found[key] = (value.startsWith('|') ? body.join('\n') : body.join(' ')).trim()
    } else if (value === '') {
      found[key] = below
        .map(line => /^\s*-\s+(.*)$/.exec(line)?.[1])
        .filter((item): item is string => item !== undefined)
        .map(unquote)
    } else if (value.startsWith('[') && value.endsWith(']')) {
      found[key] = inlineList(value)
    } else {
      found[key] = unquote(value)
    }
  }

  return found
}

function textOf(value: string | string[] | undefined): string {
  if (value === undefined) {
    return ''
  }

  return typeof value === 'string' ? value : value.join(', ')
}

function listOf(value: string | string[] | undefined): string[] {
  if (value === undefined || value === '') {
    return []
  }

  return typeof value === 'string' ? [value] : value
}

/**
 * The project data of one README: its frontmatter, or with none the first
 * `# ` heading as the goal.
 */
export function parseProject(text: string, slug: string): Project {
  const lines = text.replace(/\r\n/g, '\n').split('\n')
  const count = lines.at(-1) === '' ? lines.length - 1 : lines.length
  const found = frontmatterOf(lines)
  const heading = lines.map(line => /^#\s+(.+)$/.exec(line)?.[1]?.trim()).find(Boolean)
  const goal = textOf(found?.goal)

  return {
    goal: goal !== '' ? goal : (heading ?? slug),
    linearProject: textOf(found?.linear_project),
    canonical: listOf(found?.canonical),
    role: textOf(found?.role),
    hasFrontmatter: found !== null,
    lines: count,
  }
}

function escaped(text: string): string {
  return text.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')
}

/**
 * The distinct slugs a text names as `<root>/<slug>/README.md`.
 */
export function slugsIn(text: string, root: string): string[] {
  const pattern = new RegExp(`${escaped(root)}/([A-Za-z0-9][A-Za-z0-9._-]*)/README\\.md`, 'g')
  const slugs = [...text.matchAll(pattern)].map(match => match[1] ?? '')

  return [...new Set(slugs)].filter(slug => slug !== '' && !slug.includes('..'))
}

export function isSlug(text: string): boolean {
  return /^[A-Za-z0-9][A-Za-z0-9._-]*$/.test(text) && !text.includes('..')
}

export const RESERVED_WORDS = ['new', 'off', 'handoff', 'done'] as const

export const GOAL_TODO = 'TODO: write the goal of this project'

/**
 * A name `/orch new` takes: lowercase letters, digits and `-`, no dot and no
 * path separator, and not a word the command itself reads.
 */
export function isNewSlug(text: string): boolean {
  return /^[a-z0-9][a-z0-9-]*$/.test(text) && !(RESERVED_WORDS as readonly string[]).includes(text)
}

/**
 * The README a new project starts with: a pointer file. The goal is written
 * as a JSON string, which is a YAML double-quoted value too.
 */
export function scaffoldOf(slug: string, goal: string, updatedAt: string): string {
  return `---
goal: ${JSON.stringify(goal === '' ? GOAL_TODO : goal)}
linear_project: ""
canonical: []
---
# ${slug}

last updated: ${updatedAt}

## State
Nothing yet. Write the current state here, or point to a state file.

## Open lanes
None.

## Pending decisions
None.

## Restart steps
1. Read this file, then the files under Pointers that you need.

## Pointers
- \`lanes/\`: one file for each lane.
- \`briefs/\`: the lane briefs.
- \`docs/\`: reference documents.
`
}
