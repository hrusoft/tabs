import { readFileSync } from 'node:fs'
import { describe, expect, it } from 'vitest'

const packageJson = JSON.parse(
  readFileSync(new URL('../../../package.json', import.meta.url), 'utf8')
) as {
  scripts: Record<string, string>
}

describe('package.json dist scripts', () => {
  it('disables implicit electron-builder publishing for dist:mac', () => {
    expect(packageJson.scripts['dist:mac']).toMatch(/--publish(?:=|\s+)never\b/)
  })

  it('disables implicit electron-builder publishing for dist:mac:universal', () => {
    expect(packageJson.scripts['dist:mac:universal']).toContain('--publish never')
  })
})
