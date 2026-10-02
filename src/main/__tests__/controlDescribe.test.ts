import { describe, expect, it } from 'vitest'
import { ALL_CONTROL_VERB_SPECS } from '../../shared/controlSpecRegistry'
import { describeCommand, indexLineFor, usageFor } from '../controlDescribe'

/**
 * `describeCommand`/`indexLineFor`/`usageFor` are what `capabilities`
 * (compact index) and `describe` (full reference) actually serve — this
 * checks the formatter produces sane output for every spec the census
 * declares, core's own six included, so a spec that would describe itself
 * badly is caught here rather than by an agent reading a broken `describe`
 * response.
 */
describe('control verb describe formatting', () => {
  it('gives every command a non-empty summary and a usage line naming the command', () => {
    for (const spec of ALL_CONTROL_VERB_SPECS) {
      expect(spec.summary, `${spec.command} summary`).toMatch(/\S/)
      expect(usageFor(spec), `${spec.command} usage`).toContain(`tabs-ctl ${spec.command}`)
    }
  })

  it('marks each required flag in its usage line, and every other flag as optional', () => {
    for (const spec of ALL_CONTROL_VERB_SPECS) {
      for (const [flag, def] of Object.entries(spec.flags ?? {})) {
        const usage = usageFor(spec)
        if (def.required) {
          expect(usage, `${spec.command} usage should require --${flag}`).toContain(`--${flag}`)
          expect(usage, `${spec.command} usage should not bracket --${flag}`).not.toContain(
            `[--${flag}`
          )
        } else {
          expect(usage, `${spec.command} usage should bracket --${flag}`).toContain(`[--${flag}`)
        }
      }
    }
  })

  it('describes a target-composing command’s target forms', () => {
    for (const spec of ALL_CONTROL_VERB_SPECS) {
      if (spec.targetCompose !== 'elementTarget') continue
      const described = describeCommand(spec)
      expect(described.target, `${spec.command} target doc`).toMatch(/--ref/)
      expect(described.target, `${spec.command} target doc`).toMatch(/--role/)
    }
  })

  it('carries the wire schema through unchanged, for every command', () => {
    for (const spec of ALL_CONTROL_VERB_SPECS) {
      expect(describeCommand(spec).wire).toBe(spec.wire)
    }
  })

  it('names every flag exactly once in describeCommand’s output', () => {
    for (const spec of ALL_CONTROL_VERB_SPECS) {
      const described = describeCommand(spec)
      expect(Object.keys(described.flags as object).sort()).toEqual(
        Object.keys(spec.flags ?? {}).sort()
      )
    }
  })

  it('builds a compact index line per command, one line each', () => {
    for (const spec of ALL_CONTROL_VERB_SPECS) {
      const line = indexLineFor(spec)
      expect(line, `${spec.command} index line`).not.toContain('\n')
      expect(line, `${spec.command} index line`).toContain(spec.summary)
    }
  })

  it('names every command exactly once across the whole census', () => {
    const commands = ALL_CONTROL_VERB_SPECS.map((spec) => spec.command)
    expect(new Set(commands).size).toBe(commands.length)
  })
})
