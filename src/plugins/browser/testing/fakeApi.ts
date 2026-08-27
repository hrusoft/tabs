import type { NavDirection } from '@shared/model/navigation'
import type { FakeContentHost } from '@shared/testing/fakeApiHandle'
import { BrowserGuestEvent, BrowserGuestMethod } from '../shared/ipc'
import type { BrowserGuestFakeHandle } from '../shared/testing'

/**
 * The browser's fake main entry, installed into the fake content bridge, plus
 * the driver that fires its guest events.
 *
 * Both events are real coverage rather than shape-filling: core does not
 * subscribe to either guest event, so the only path to them is a content
 * type's own wiring, and the jsdom tier exercises exactly that through
 * `__fakeApi.emitNavKey` / `emitGuestPointerDown` (see
 * testing/registerTestContent.ts, which installs both forwarders the same way
 * the package's activate does).
 *
 * What the fake cannot stand in for is the guest itself — whether a real press
 * inside a `<webview>` produces the event at all is an Electron-tier
 * question, answered in e2e/browser.spec.ts.
 */
export function installFake(host: FakeContentHost): BrowserGuestFakeHandle {
  host.on(BrowserGuestMethod.attached, () => {})
  host.on(BrowserGuestMethod.detached, () => {})
  return {
    emitNavKey: (direction: NavDirection) => host.emit(BrowserGuestEvent.navKey, direction),
    emitGuestPointerDown: (paneId: string) => host.emit(BrowserGuestEvent.pointerDown, paneId)
  }
}
