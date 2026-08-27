import { homedir } from 'node:os'
import { describe, expect, it } from 'vitest'
import { resolveCwd, resolveShell } from '../terminal'

describe('resolveShell', () => {
  it('uses $SHELL when set, without consulting the filesystem', () => {
    const shell = resolveShell({
      env: { SHELL: '/usr/local/bin/fish' },
      exists: () => {
        throw new Error('should not be called when $SHELL is set')
      }
    })
    expect(shell).toBe('/usr/local/bin/fish')
  })

  it('falls back to /bin/zsh when $SHELL is unset and zsh exists', () => {
    const shell = resolveShell({
      env: {},
      exists: (path) => path === '/bin/zsh'
    })
    expect(shell).toBe('/bin/zsh')
  })

  it('falls back to /bin/bash when $SHELL is unset and only bash exists', () => {
    const shell = resolveShell({
      env: {},
      exists: (path) => path === '/bin/bash'
    })
    expect(shell).toBe('/bin/bash')
  })

  it('falls back to the last default even if nothing exists, rather than throwing', () => {
    const shell = resolveShell({
      env: {},
      exists: () => false
    })
    expect(shell).toBe('/bin/bash')
  })

  it('treats an empty string $SHELL the same as unset', () => {
    const shell = resolveShell({
      env: { SHELL: '' },
      exists: (path) => path === '/bin/zsh'
    })
    expect(shell).toBe('/bin/zsh')
  })
})

describe('resolveCwd', () => {
  it('expands a bare "~" to the home directory', () => {
    expect(resolveCwd('~')).toBe(homedir())
  })

  it('expands a "~/" prefix to the home directory', () => {
    expect(resolveCwd('~/projects')).toBe(`${homedir()}/projects`)
  })

  it('leaves an absolute path untouched', () => {
    expect(resolveCwd('/tmp')).toBe('/tmp')
  })

  it('defaults to the home directory when undefined', () => {
    expect(resolveCwd(undefined)).toBe(homedir())
  })
})
