/**
 * Whether this process is running under the e2e harness — one const for all of
 * main, not one `process.env` read per consumer, for the same reason
 * `platform.ts` holds exactly one.
 *
 * Five modules branch on it and they must agree, because between them they
 * implement a single rule: **never put a native dialog or a shown window in
 * front of a Playwright run.** `windows.ts` never calls `show()`/`focus()`,
 * `closeDialogs.ts` skips both confirmations and auto-answers them,
 * `index.ts` hides the Dock icon and installs the reset hook, `settings.ts`
 * overlays each content type's test baseline, and the git tree package's main
 * entry answers "cancelled" instead of opening its directory picker.
 * Playwright drives a renderer over CDP and can reach none of those surfaces,
 * so anything that blocks on one hangs the worker until its timeout rather
 * than failing.
 *
 * That fifth one is the interesting entry rather than a footnote: it is a
 * *package*, reaching this flag through the re-export in `plugin/api.ts`. Any
 * content type that opens a native dialog joins this list, so the roster is
 * not closed by core's own module count — check it when adding one.
 *
 * Set by e2e/helpers/launch.ts. A normal run never defines it, so every branch
 * guarded by this is dead code in a shipped app.
 */
export const e2eHidden = process.env.E2E_HIDDEN === '1'
