import type { NavDirection } from '../../../shared/model/navigation'

/** What a test can drive on the browser type's faked `window.api` namespace. */
export interface BrowserGuestFakeHandle {
  /** Fires browserGuest.onNavKey, as a focused guest forwarding a nav press would. */
  emitNavKey(direction: NavDirection): void
  /** Fires browserGuest.onPointerDown, as a press landing inside a guest page would. */
  emitGuestPointerDown(paneId: string): void
}
