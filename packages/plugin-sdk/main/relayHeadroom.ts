/**
 * Margin a relay budget keeps above a renderer-side wait it must outlive.
 * A plugin-facing constant because the budgets that need it are declared by
 * the content types whose verbs do the waiting (each type's own
 * `MainControlVerbTable`), while the relay it applies to is core's — split
 * out of `src/main/externalControl.ts`, which stays core-owned (the relay
 * itself, plus transport/dispatch/the ownership ledger).
 */
export const RELAY_HEADROOM_MS = 5000
