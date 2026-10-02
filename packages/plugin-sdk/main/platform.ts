import type { Platform } from '../shared/shortcuts'

/**
 * Which platform's modifier conventions this process follows — one const for
 * all of main, not one per consumer.
 *
 * Two consumers read it, and they are the two halves of one shortcut: menu.ts
 * turns a binding into a menu accelerator, and guestNavKeys.ts matches the same
 * binding against a keypress inside a `<webview>`. They have to agree.
 *
 * Note this is only the shortcuts-facing answer. Elsewhere in main,
 * `process.platform === 'darwin'` guards genuinely macOS-specific behavior
 * (menu roles, the process probes) rather than a modifier convention, and
 * belongs where it is.
 */
export const platform: Platform = process.platform === 'darwin' ? 'darwin' : 'other'
