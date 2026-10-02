/**
 * The roles a `--role` filter can name: every non-abstract WAI-ARIA 1.2 role,
 * plus the 1.3 additions pages already use. `read-page --role` and the
 * semantic targets of click/hover/type/form-input compare against an
 * element's explicit `role` attribute or the role derived from its tag
 * (`roleFor` in pageScripts.ts), so a name outside this vocabulary can never
 * match anything — and `read-page --role nonsense` used to answer `total: 0`,
 * which reads as "this page has none" rather than "that isn't a role". The
 * same refusal read-network gives an unknown `--method`/`--resource-type`.
 *
 * The DPUB (`doc-*`) and Graphics (`graphics-*`) module roles are accepted by
 * prefix rather than listed: they are real roles pages use, and listing both
 * modules in every refusal would bury the common ones.
 */
export const ARIA_ROLES = [
  'alert',
  'alertdialog',
  'application',
  'article',
  'banner',
  'blockquote',
  'button',
  'caption',
  'cell',
  'checkbox',
  'code',
  'columnheader',
  'combobox',
  'comment',
  'complementary',
  'contentinfo',
  'definition',
  'deletion',
  'dialog',
  'directory',
  'document',
  'emphasis',
  'feed',
  'figure',
  'form',
  'generic',
  'grid',
  'gridcell',
  'group',
  'heading',
  'image',
  'img',
  'insertion',
  'link',
  'list',
  'listbox',
  'listitem',
  'log',
  'main',
  'mark',
  'marquee',
  'math',
  'menu',
  'menubar',
  'menuitem',
  'menuitemcheckbox',
  'menuitemradio',
  'meter',
  'navigation',
  'none',
  'note',
  'option',
  'paragraph',
  'presentation',
  'progressbar',
  'radio',
  'radiogroup',
  'region',
  'row',
  'rowgroup',
  'rowheader',
  'scrollbar',
  'search',
  'searchbox',
  'separator',
  'slider',
  'spinbutton',
  'status',
  'strong',
  'subscript',
  'suggestion',
  'superscript',
  'switch',
  'tab',
  'table',
  'tablist',
  'tabpanel',
  'term',
  'textbox',
  'time',
  'timer',
  'toolbar',
  'tooltip',
  'tree',
  'treegrid',
  'treeitem'
] as const

const KNOWN_ROLES = new Set<string>(ARIA_ROLES)
const MODULE_ROLE_PREFIXES = ['doc-', 'graphics-']

/**
 * Refusal message for a `--role` that names no ARIA role, or undefined when it
 * does. Compared case-insensitively, like the match itself (roleMatcher in
 * pageScripts.ts).
 */
export function roleFilterError(role: string): string | undefined {
  const wanted = role.toLowerCase()
  if (KNOWN_ROLES.has(wanted)) return undefined
  if (
    MODULE_ROLE_PREFIXES.some(
      (prefix) => wanted.startsWith(prefix) && wanted.length > prefix.length
    )
  ) {
    return undefined
  }
  return `unknown role ${JSON.stringify(role)} — role must be a WAI-ARIA role, one of: ${ARIA_ROLES.join(', ')} (or a doc-*/graphics-* module role)`
}
