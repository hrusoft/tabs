import { isSafeExternalUrl } from '@shared/url'
import { terminalCtx } from './pluginContext'

/**
 * Whether a mouse event on a link should follow it: Cmd-click on macOS,
 * Ctrl-click elsewhere — the same contract as macOS Terminal, iTerm2 and
 * VS Code's terminal.
 *
 * The modifier is required because a plain click is how you focus a terminal
 * pane; clicking into a shell that happens to have a URL under the cursor
 * must never launch a browser. The left-button check matters too: xterm's
 * Linkifier fires `activate` from its mouseup handler without looking at
 * `button`, so a right-click on a link would otherwise follow it — and on
 * macOS that guard doubles as the one that rejects Ctrl+left-click, which
 * Chromium delivers as button 2.
 *
 * Exported for its unit tests; `openTerminalLink` is the activate path.
 */
export function isLinkActivationEvent(event: MouseEvent): boolean {
  return event.button === 0 && (event.metaKey || event.ctrlKey)
}

/**
 * The one activate path for both kinds of terminal link — OSC 8 hyperlinks
 * (xterm core's own provider, via the `linkHandler` option) and plain-text
 * URLs in the scrollback (WebLinksAddon). Main re-validates the URL; this
 * check just avoids a pointless round trip.
 */
export function openTerminalLink(event: MouseEvent, uri: string): void {
  if (!isLinkActivationEvent(event)) return
  if (!isSafeExternalUrl(uri)) return
  terminalCtx.get().openExternal(uri)
}
