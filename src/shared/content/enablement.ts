import type { Settings } from '../settings'
import { CONTENT_TYPE_MANIFESTS, type ContentTypeManifest } from './registry'

/**
 * Whether a content type is offered to the user, and the settings key that
 * decides it.
 *
 * ## What "disabled" means, and what it deliberately does not
 *
 * Disabling a type removes every way to make a *new* instance of it: its
 * pane-header button (see PaneHeaderControls.tsx), the clone every other
 * creation path performs (content/contentLike.ts — splitting a terminal opens
 * another terminal, and a surviving pane would otherwise be a factory
 * indefinitely), the external-control verb that creates one, and its page in
 * the Settings sidebar.
 *
 * It does **not** unregister anything. Panes already open keep their renderer
 * and keep running — treating disabled as unregistered would drop a live
 * shell's rendering the next time the layout normalized, which is
 * destructive-adjacent for a setting a user can flip by accident. Nor does it
 * gate code loading: every content module still registers in main, and a
 * dormant IPC handler is cheaper than a "restart required" flow. Enablement is
 * a UI/creation gate.
 *
 * The type's own settings blob (`Settings.contentTypes[type]`) is untouched
 * either way, so re-enabling restores a hand-tuned palette exactly as it was.
 *
 * ## Why the gate does not consult `canDisable`
 *
 * `canDisable` on the census (see ./registry.ts) says whether the UI *offers*
 * a checkbox — that is `togglableContentTypes` below, and the Settings page's
 * only input. The gate itself honours plain membership of the list, for any
 * type at all. Two reasons: a type that a future plugin loader has not
 * registered yet must still be able to hold a disabled entry, and the test
 * tiers register a stub content type that appears in no census, which is what
 * lets them drive this exact code path rather than a copy of it.
 *
 * A structural type ('tabs'/'split'/'empty') landing in the list by way of a
 * hand-edited settings.json is harmless rather than a wedge: they contribute
 * no creation action, they have no settings page, and `createContentLike`
 * falls back to an empty leaf unconditionally — including when the origin was
 * already empty.
 */

/**
 * Whether new content of `type` may be created. Absent from the list means
 * enabled, so a content type that ships later defaults on rather than needing
 * every existing settings.json to name it.
 *
 * Takes the list rather than a whole `Settings` on purpose: the renderer call
 * sites subscribe to this one key (`useSettingsStore(s => s.disabledContentTypes)`)
 * rather than to the store as a whole, because a header rendered per pane must
 * not re-render on every tick of, say, the dimming-intensity slider drag.
 */
export function isContentTypeEnabled(
  disabledContentTypes: Settings['disabledContentTypes'],
  type: string
): boolean {
  return !disabledContentTypes.includes(type)
}

/**
 * Coerces whatever a settings.json holds under `disabledContentTypes` into a
 * usable list — the same contract `sanitizeShortcutOverrides` has, and for the
 * same reason: a hand-edited or truncated file must degrade to "nothing is
 * disabled" rather than throw, because a throw out of migrateSettings resets
 * the whole file (see loadSettings in src/main/settings.ts).
 *
 * Entries are not checked against the census on purpose — see the note above.
 */
export function sanitizeDisabledContentTypes(value: unknown): string[] {
  if (!Array.isArray(value)) return []
  return [...new Set(value.filter((entry): entry is string => typeof entry === 'string'))]
}

/**
 * The census entries the Settings window offers a checkbox for. Derived from
 * the census rather than listed again, so a new content type appears in the
 * UI with no edit here — which is the whole point of `canDisable` living on
 * the manifest rather than in a list of its own.
 */
export function togglableContentTypes(): ContentTypeManifest[] {
  return CONTENT_TYPE_MANIFESTS.filter((manifest) => manifest.canDisable)
}
