import type { FakeContentHost } from '@shared/testing/fakeApiHandle'
import { TerminalMethod } from '../shared/ipc'

/**
 * The terminal's fake main entry, installed into the fake content bridge.
 *
 * Inert on purpose: no non-Electron tier renders a real terminal (both
 * substitute the stub content def — see testing/registerTestContent.ts), so
 * this registers just enough for the bridge's `handle` methods to answer
 * rather than reject if a future tier ever mounts one, and contributes
 * nothing to the driver handle. The fire-and-forget methods (write, resize)
 * need no registration at all — the fake bridge's `send` is already silent
 * for an unregistered method, like a real ipcMain.on with no listener.
 */
export function installFake(host: FakeContentHost): Record<never, never> {
  host.handle(TerminalMethod.create, () => 4242)
  host.handle(TerminalMethod.dispose, () => undefined)
  host.handle(TerminalMethod.getCwd, () => undefined)
  return {}
}
