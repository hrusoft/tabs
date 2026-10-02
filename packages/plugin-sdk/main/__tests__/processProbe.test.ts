import { describe, expect, it } from 'vitest'
import { parseLsofCwd, parsePgidTpgid, parseProcStatPgidTpgid } from '../processProbe'

describe('parseLsofCwd', () => {
  it('extracts the path from the n-prefixed field line', () => {
    const stdout = 'p12345\nfcwd\nn/Users/nick/work/tabs\n'
    expect(parseLsofCwd(stdout)).toBe('/Users/nick/work/tabs')
  })

  it('returns undefined when there is no n-prefixed line', () => {
    expect(parseLsofCwd('p12345\nfcwd\n')).toBeUndefined()
  })

  it('returns undefined for empty output', () => {
    expect(parseLsofCwd('')).toBeUndefined()
  })
})

describe('parsePgidTpgid', () => {
  it('parses macOS/BSD `ps -o pgid=,tpgid=` output', () => {
    expect(parsePgidTpgid('12345 67890\n')).toEqual({ pgid: 12345, tpgid: 67890 })
  })

  it('reports an idle shell as its own foreground group', () => {
    expect(parsePgidTpgid('12345 12345\n')).toEqual({ pgid: 12345, tpgid: 12345 })
  })

  it('returns undefined for malformed output', () => {
    expect(parsePgidTpgid('')).toBeUndefined()
    expect(parsePgidTpgid('not a pid\n')).toBeUndefined()
  })
})

describe('parseProcStatPgidTpgid', () => {
  it('parses the pgrp/tpgid fields out of /proc/<pid>/stat', () => {
    const stat = '12345 (zsh) S 100 12345 12345 34816 67890 4194304 0 0 0 0 0 0'
    expect(parseProcStatPgidTpgid(stat)).toEqual({ pgid: 12345, tpgid: 67890 })
  })

  it('handles a comm field containing spaces and parens', () => {
    const stat = '12345 (my (weird) shell) S 100 12345 12345 34816 67890 4194304'
    expect(parseProcStatPgidTpgid(stat)).toEqual({ pgid: 12345, tpgid: 67890 })
  })

  it('returns undefined when there is no closing paren', () => {
    expect(parseProcStatPgidTpgid('garbage')).toBeUndefined()
  })
})
