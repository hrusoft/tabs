/**
 * What the fake content bridge lends a package's testing piece — a fake
 * main entry, deliberately mirroring `MainPluginIpc` plus the `emit` real
 * main performs through `ipc.emit`: the piece registers the same method
 * names its real main entry does and fires the same events, so the
 * package's renderer client (over `ctx.ipc`) cannot tell the tiers apart.
 * Scoped to the piece's own type by the host that hands it over.
 *
 * Split out of `src/shared/testing/fakeApiHandle.ts` — the only export of
 * that file any plugin's own `testing/fakeApi.ts` actually imports
 * (verified by grep: all three built-in packages import exactly this and
 * nothing else). `CoreFakeApiHandle`/`TestSeed`/`ExtraStubType`/
 * `FakeApiHandle` reference core-wide, whole-app test-driver surface
 * (`Api`, `LayoutSnapshot`, `Settings`, `ShortcutActionId`) with nothing
 * plugin-specific about them, and stay core-owned.
 */
export interface FakeContentHost {
  /** Registers a request/response method; the fake `invoke` resolves with its return. */
  handle(method: string, handler: (...args: unknown[]) => unknown): void
  /** Registers a fire-and-forget method for the fake `send`. */
  on(method: string, listener: (...args: unknown[]) => void): void
  /** Emits an event to every `ctx.ipc.on` subscriber (names may embed ids). */
  emit(event: string, ...args: unknown[]): void
}
