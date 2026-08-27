import { execFileSync } from 'node:child_process'
import path from 'node:path'
import { describe, expect, it } from 'vitest'
// Electron-free by construction (see networkLog.ts's own doc), which is what
// lets this unit test read the vocabularies the app enforces.
import { NETWORK_METHODS, NETWORK_RESOURCE_TYPES } from '../../plugins/browser/main/networkLog'
import {
  DEFAULT_PAGE_TEXT_MAX,
  EDITING_COMMANDS,
  EXECUTE_RESULT_MAX,
  NETWORK_BODY_HARD_MAX,
  NETWORK_BODY_MAX,
  NETWORK_LOG_CAPACITY,
  PAGE_TEXT_HARD_MAX,
  WAIT_DEFAULT_POLL_MS,
  WAIT_DEFAULT_TIMEOUT_MS,
  WAIT_IDLE_QUIET_MS,
  WAIT_MAX_TIMEOUT_MS
} from '../../plugins/browser/shared/externalControl'
import { CONTROL_REQUEST_TYPES, MAX_BATCH_SIZE } from '../externalControl'

/**
 * Guards the one seam the compiler can't reach.
 *
 * TypeScript forces main and the renderer to handle every `ControlRequest`
 * variant, but `tabs-ctl` is a standalone, untyped Node script — a verb added
 * to the protocol without a CLI command, or a CLI command inventing a verb
 * that doesn't exist, would otherwise ship silently.
 *
 * Deliberately runs the **real shipped executable** as a subprocess rather
 * than importing a copy of its command table: the file that gets symlinked
 * into an agent's skills directory is the thing under test, same reasoning as
 * `runTabsCtl` in e2e/external-control.spec.ts. `describe` needs no socket and
 * no Tabs environment, so this stays a unit test.
 */
const TABS_CTL = path.resolve(
  import.meta.dirname,
  '../../../resources/skills/tabs/scripts/tabs-ctl'
)

interface DescribedCommand {
  command: string
  summary: string
  usage: string
  flags: Record<
    string,
    { required: boolean; type?: string; enum?: string[]; min?: number; doc?: string }
  >
  wire: {
    type: string
    properties: Record<string, unknown> & { type: { const: string } }
    required: string[]
    additionalProperties: boolean
  }
  result?: Record<string, unknown>
}

function runDescribe(...args: string[]): Record<string, unknown> {
  // The environment is stripped so this also proves `describe` answers without
  // TABS_PANE_ID / TABS_CONTROL_SOCKET — an agent has to be able to learn the
  // surface before it knows whether it's inside Tabs.
  const base = { ...process.env }
  delete base.TABS_CONTROL_SOCKET
  delete base.TABS_PANE_ID
  return JSON.parse(execFileSync(TABS_CTL, ['describe', ...args], { encoding: 'utf8', env: base }))
}

const full = runDescribe('--full')
const commands = full.commands as Record<string, DescribedCommand>

describe('tabs-ctl describe', () => {
  it('states the shared wire caps, so the CLI cannot quietly disagree with the app', () => {
    // The CLI is an untyped standalone script, so its restatement of the caps
    // (batch size, page-text bounds) is unreachable by the compiler — this is
    // the same seam as the verb coverage below, guarded the same way.
    expect(full.limits).toEqual({
      maxBatchRequests: MAX_BATCH_SIZE,
      pageTextDefaultMax: DEFAULT_PAGE_TEXT_MAX,
      pageTextHardMax: PAGE_TEXT_HARD_MAX,
      waitDefaultTimeoutMs: WAIT_DEFAULT_TIMEOUT_MS,
      waitMaxTimeoutMs: WAIT_MAX_TIMEOUT_MS,
      waitIdleQuietMs: WAIT_IDLE_QUIET_MS,
      waitDefaultPollMs: WAIT_DEFAULT_POLL_MS,
      networkBodyMax: NETWORK_BODY_MAX,
      networkBodyHardMax: NETWORK_BODY_HARD_MAX,
      networkRequestCapacity: NETWORK_LOG_CAPACITY,
      executeResultMax: EXECUTE_RESULT_MAX
    })
  })

  it('names exactly the filter vocabularies read-network enforces', () => {
    // Same seam as the caps above, one level out: these lists are prose in the
    // CLI's own docs, which is what an agent reads to learn what --method and
    // --resource-type accept. The app is what actually refuses a value outside
    // them, so a type added there and not here leaves the CLI confidently
    // wrong with nothing else to catch it.
    const readNetwork = commands['read-network']!
    // The list is the first sentence after the colon: "…: a, b, or c." —
    // anything the flag adds afterwards (resource-type's note about xhr) is
    // prose, not vocabulary.
    const named = (doc: string): string[] =>
      doc
        .split(/:\s*/)[1]!
        .split(/\.(?:\s|$)/)[0]!
        .split(/,\s*(?:or\s+)?/)

    expect(named(readNetwork.flags.method!.doc ?? '')).toEqual([...NETWORK_METHODS])
    expect(named(readNetwork.flags['resource-type']!.doc ?? '')).toEqual([
      ...NETWORK_RESOURCE_TYPES
    ])
  })

  it('offers exactly the editing commands the app implements', () => {
    // The same restatement seam, and the one with teeth: a command added to
    // EDITING_COMMANDS but not to the CLI is a capability an agent can never
    // discover, and one offered here but unimplemented is an error the agent
    // only finds by trying it. The clipboard trio is deliberately absent from
    // both — asserted, so re-adding it has to be a decision rather than a
    // drive-by.
    expect(commands.key!.flags.command!.enum).toEqual([...EDITING_COMMANDS])
    expect(EDITING_COMMANDS).not.toContain('copy')
    expect(EDITING_COMMANDS).not.toContain('cut')
    expect(EDITING_COMMANDS).not.toContain('paste')
  })

  it('covers exactly the verbs the protocol defines', () => {
    const described = Object.values(commands).map((command) => command.wire.properties.type.const)

    expect(new Set(described)).toEqual(new Set(CONTROL_REQUEST_TYPES))
  })

  it('maps each command to a distinct verb', () => {
    const described = Object.values(commands).map((command) => command.wire.properties.type.const)

    expect(described).toHaveLength(new Set(described).size)
  })

  it('answers without a Tabs environment, and reports its payload version', () => {
    expect(full.version).toBe(1)
  })

  it('gives every command a summary and a usage line', () => {
    for (const [name, command] of Object.entries(commands)) {
      expect(command.summary, `${name} summary`).toMatch(/\S/)
      expect(command.usage, `${name} usage`).toContain(`tabs-ctl ${name}`)
    }
  })

  it('emits a closed wire schema whose required fields are all declared', () => {
    for (const [name, command] of Object.entries(commands)) {
      expect(command.wire.additionalProperties, `${name} additionalProperties`).toBe(false)
      // `paneId` is filled in by the app from the caller's environment, so it
      // must never appear in a schema a caller composes a batch from.
      expect(Object.keys(command.wire.properties), `${name} properties`).not.toContain('paneId')
      for (const field of command.wire.required) {
        expect(Object.keys(command.wire.properties), `${name} requires ${field}`).toContain(field)
      }
    }
  })

  it('defaults to a compact index and drills down per command', () => {
    const index = runDescribe().commands as Record<string, string>

    expect(Object.keys(index)).toEqual(Object.keys(commands))
    expect(index.click).toContain('tabs-ctl click')
    // The compact form is one line per command, so it stays cheap to load.
    for (const [name, line] of Object.entries(index)) {
      expect(line, `${name} index line`).not.toContain('\n')
    }

    const one = runDescribe('--command', 'click') as unknown as DescribedCommand
    expect(one.command).toBe('click')
    expect(one.wire.properties.type.const).toBe('click')
  })

  it('surfaces a numeric floor in both the flag description and the wire schema', () => {
    const spec = runDescribe('--command', 'get-page-text') as unknown as DescribedCommand

    expect(spec.flags['max-length']).toMatchObject({ type: 'number', min: 1 })
    expect(spec.wire.properties.maxLength).toEqual({ type: 'number', minimum: 1 })
  })

  it('describes the ElementTarget union for the verbs that take one', () => {
    for (const name of ['click', 'hover', 'type']) {
      const target = commands[name]!.wire.properties.target as {
        oneOf: { properties: Record<string, unknown> }[]
      }
      // Ref, coordinate, and the semantic form.
      expect(target.oneOf, `${name} target`).toHaveLength(3)
      const semantic = target.oneOf.find((branch) => 'role' in branch.properties)
      expect(Object.keys(semantic?.properties ?? {}).sort()).toEqual([
        'name',
        'nth',
        'role',
        'selector'
      ])
    }
  })
})

/**
 * The other half of deriving the parser from the command table: validation is
 * now uniform rather than hand-written per branch, so it's worth pinning the
 * messages a caller actually has to act on. Points at a socket that cannot
 * exist — every case here must be rejected before anything is sent.
 */
function runCommand(...args: string[]): { ok: boolean; error?: string } {
  const env = {
    ...process.env,
    TABS_PANE_ID: 'test-pane',
    TABS_CONTROL_SOCKET: '/nonexistent.sock'
  }
  try {
    return JSON.parse(execFileSync(TABS_CTL, args, { encoding: 'utf8', env }))
  } catch (error) {
    // tabs-ctl exits non-zero on `{ok:false}`, so the JSON is still on stdout.
    return JSON.parse((error as { stdout: string }).stdout)
  }
}

describe('tabs-ctl argument validation', () => {
  it('names the valid flags when one is misspelled, rather than reporting it as missing', () => {
    const response = runCommand('click', '--panee', 'x')

    // Previously `--panee` was silently dropped and this surfaced as the
    // confusing "--pane is required".
    expect(response.error).toContain('unknown flag --panee')
    expect(response.error).toContain('--pane')
    // Flags consumed by the ElementTarget builder count as valid too.
    expect(response.error).toContain('--ref')
  })

  it('rejects a value outside a flag’s enum', () => {
    expect(runCommand('scroll', '--pane', 'p', '--direction', 'sideways').error).toContain(
      'must be one of up, down, left, right'
    )
  })

  it('rejects a non-numeric value for a numeric flag', () => {
    expect(runCommand('get-page-text', '--pane', 'p', '--max-length', 'abc').error).toContain(
      'must be a number'
    )
  })

  it('reports a missing required flag', () => {
    expect(runCommand('navigate', '--pane', 'p').error).toContain('--url is required')
  })

  it('rejects numeric garbage below a flag’s floor as loudly as a non-numeric spelling', () => {
    // --max-length -5 used to go over the wire and be silently ignored while
    // --max-length abc errored — the same garbage must fail either way.
    expect(runCommand('get-page-text', '--pane', 'p', '--max-length', '-5').error).toContain(
      '--max-length must be at least 1 (got -5)'
    )
    expect(runCommand('get-page-text', '--pane', 'p', '--max-length', '0').error).toContain(
      'must be at least 1'
    )
    expect(
      runCommand('find', '--pane', 'p', '--description', 'x', '--max-results', '0').error
    ).toContain('must be at least 1')
    expect(runCommand('scroll', '--pane', 'p', '--amount', '-100').error).toContain(
      'must be at least 1'
    )
    expect(runCommand('read-console', '--pane', 'p', '--since-seq', '-1').error).toContain(
      'must be at least 0'
    )
    expect(runCommand('read-network', '--pane', 'p', '--since-seq', '-1').error).toContain(
      'must be at least 0'
    )
  })

  it('leaves legitimate floors alone: seq 0 and the app-clamped wait knobs pass', () => {
    // 0 is a real sequence floor, and --timeout 0 is a documented app-side
    // clamp (one immediate check) — reaching the connection attempt is the
    // assertion that validation let them through.
    expect(runCommand('read-console', '--pane', 'p', '--since-seq', '0').error).toContain(
      'could not reach Tabs'
    )
    expect(runCommand('wait-for', '--pane', 'p', '--text', 'x', '--timeout', '0').error).toContain(
      'could not reach Tabs'
    )
  })

  it('reports an incomplete element target', () => {
    expect(runCommand('click', '--pane', 'p').error).toContain(
      '--role/--name/--selector, --ref, or both --x and --y'
    )
    expect(runCommand('click', '--pane', 'p', '--x', '10').error).toContain(
      'needs both --x and --y'
    )
  })

  it('rejects a mix of target forms instead of silently ignoring half of one', () => {
    const mixed = runCommand('click', '--pane', 'p', '--ref', 'e1', '--name', 'Save')
    expect(mixed.error).toContain('--ref')
    expect(mixed.error).toContain('--name')
    expect(mixed.error).toContain('pass only one')
    expect(
      runCommand('click', '--pane', 'p', '--x', '1', '--y', '2', '--role', 'button').error
    ).toContain('pass only one')
  })

  it('constrains --nth to semantic targeting, as a non-negative integer', () => {
    expect(runCommand('click', '--pane', 'p', '--ref', 'e1', '--nth', '0').error).toContain(
      '--nth only applies'
    )
    expect(runCommand('click', '--pane', 'p', '--nth', '1').error).toContain('--nth only applies')
    expect(runCommand('click', '--pane', 'p', '--name', 'Save', '--nth', '-1').error).toContain(
      'non-negative integer'
    )
    expect(runCommand('click', '--pane', 'p', '--name', 'Save', '--nth', 'abc').error).toContain(
      'non-negative integer'
    )
  })

  it('rejects a bare semantic flag rather than matching the string "true"', () => {
    expect(runCommand('click', '--pane', 'p', '--name').error).toContain('--name needs a value')
  })

  it('sends a well-formed semantic target through to the socket', () => {
    expect(
      runCommand('click', '--pane', 'p', '--role', 'button', '--name', 'Save', '--nth', '1').error
    ).toContain('could not reach Tabs')
    expect(runCommand('type', '--pane', 'p', '--selector', '#q', '--text', 'hi').error).toContain(
      'could not reach Tabs'
    )
  })

  it('rejects a non-numeric coordinate target instead of sending NaN over the wire', () => {
    expect(runCommand('click', '--pane', 'p', '--x', 'abc', '--y', '10').error).toContain(
      '--x and --y must be numbers'
    )
  })

  it('points an unknown command at describe', () => {
    expect(runCommand('nonsense').error).toContain("run 'tabs-ctl describe'")
  })

  it('rejects malformed JSON for a JSON-valued flag', () => {
    expect(runCommand('batch', '--requests', '{not json').error).toContain('not valid JSON')
    expect(runCommand('batch', '--requests', '{"a":1}').error).toContain('must be a JSON array')
  })

  it('sends a well-formed call through to the socket', () => {
    // Reaching the connection attempt is the assertion: everything before it
    // — flag validation, coercion, request assembly — passed.
    expect(runCommand('click', '--pane', 'p', '--ref', 'e1').error).toContain(
      'could not reach Tabs'
    )
  })

  it('binds --flag=value, including a value that itself starts with --', () => {
    // Without the `=` form, `--text --help` reads as a boolean switch
    // followed by an unknown flag — there is no other way to type a literal
    // `--help` into a page.
    expect(runCommand('type', '--pane=p', '--ref=e1', '--text=--help').error).toContain(
      'could not reach Tabs'
    )
  })

  it('rejects a batch sub-request with an unknown verb before sending anything', () => {
    const response = runCommand('batch', '--requests', JSON.stringify([{ type: 'getPagetext' }]))

    expect(response.error).toContain('requests[0]')
    expect(response.error).toContain('getPagetext')
  })
})
