/**
 * Whether this process is running under the e2e harness — one const for all of
 * main, not one `process.env` read per consumer, for the same reason
 * `platform.ts` holds exactly one.
 *
 * Five modules branch on it and they must agree, because between them they
 * implement a single rule: **never put a native dialog or a shown window in
 * front of a Playwright run.** `windows.ts` never calls `show()`/`focus()`,
 * `closeDialogs.ts` skips both confirmations and auto-answers them,
 * `index.ts` installs the reset hook, `settings.ts` overlays each content
 * type's test baseline, and the git tree package's main entry answers
 * "cancelled" instead of opening its directory picker. Playwright drives a
 * renderer over CDP and can reach none of those surfaces, so anything that
 * blocks on one hangs the worker until its timeout rather than failing.
 *
 * One thing no module may do under this flag: switch the app's activation
 * policy (hide or show its Dock icon). macOS 27 force-quits a never-shown app
 * about 30s after it leaves the Dock, which is what the e2e run's "accepted"
 * flakes were. The harness keeps e2e apps out of the Dock by launching them
 * from an `LSUIElement` clone of Electron.app instead
 * (e2e/helpers/electronClone.ts), and src/main/__tests__/activationPolicy.test.ts
 * fails on any such call. Full story in CLAUDE.md.
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
