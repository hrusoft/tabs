import type { NavDirection } from '../../../shared/model/navigation'

/** What a test can drive on the browser type's fake bridge (its testing/fakeApi.ts). */
export interface BrowserGuestFakeHandle {
  /** Emits the nav-key event, as a focused guest forwarding a nav press would. */
  emitNavKey(direction: NavDirection): void
  /** Emits the guest pointer-down event, as a press landing inside a guest page would. */
  emitGuestPointerDown(paneId: string): void
}
