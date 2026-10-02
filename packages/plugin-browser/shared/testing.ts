import type { NavDirection } from '@tabs/plugin-sdk/shared/model/types'

/** What a test can drive on the browser type's fake bridge (its testing/fakeApi.ts). */
export interface BrowserGuestFakeHandle {
  /** Emits the nav-key event, as a focused guest forwarding a nav press would. */
  emitNavKey(direction: NavDirection): void
  /** Emits the guest pointer-down event, as a press landing inside a guest page would. */
  emitGuestPointerDown(paneId: string): void
}

/**
 * The fake bridge's driver as this package's slice of it — what a test calls
 * instead of reaching `window.__fakeApi` for a browser method. Core types
 * `__fakeApi` as its own driver surface only (src/shared/testing/fakeApiHandle.ts);
 * each package's methods are merged into the same object at runtime by the
 * fake content bridge and typed here, by the package that contributes them,
 * so core never has to name a content type's test surface. Read through
 * `globalThis` rather than `window` because this module is process-agnostic.
 */
export function browserGuestFake(): BrowserGuestFakeHandle | undefined {
  return (globalThis as { __fakeApi?: BrowserGuestFakeHandle }).__fakeApi
}
