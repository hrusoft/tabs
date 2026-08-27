import { FitAddon } from '@xterm/addon-fit'
import { WebLinksAddon } from '@xterm/addon-web-links'
import { WebglAddon } from '@xterm/addon-webgl'
import { Terminal } from '@xterm/xterm'
import '@xterm/xterm/css/xterm.css'
// After xterm.css so this pane's own rules get the last word (see the
// .xterm-viewport override in it).
import './terminal.css'
import type { LeafContent } from '@shared/model/types'
import { useEffect, useRef } from 'react'
import type { ContentRendererProps } from '../../../renderer/src/plugin/api'
import type { TerminalAppearance } from '../shared/settings'
import { openTerminalLink } from './links'
import { terminalCtx } from './pluginContext'
import { terminalBridge } from './terminalBridge'
import { acquireTerminal, releaseTerminal } from './terminalRegistry'
import { getTerminalSettings, useTerminalSetting } from './terminalSettingsAccess'

/** Maps the user's terminal settings onto xterm's constructor/options shape. */
function toXtermOptions(appearance: TerminalAppearance): ConstructorParameters<typeof Terminal>[0] {
  return {
    fontFamily: appearance.fontFamily,
    fontSize: appearance.fontSize,
    lineHeight: appearance.lineHeight,
    cursorStyle: appearance.cursorStyle,
    cursorBlink: appearance.cursorBlink,
    theme: {
      background: appearance.background,
      foreground: appearance.foreground,
      cursor: appearance.cursorColor,
      // No separate setting for this — the glyph drawn on top of a filled
      // block cursor conventionally matches the pane background.
      cursorAccent: appearance.background,
      selectionBackground: appearance.selectionBackground,
      // TerminalAnsiColors deliberately uses xterm ITheme's own 16 key names.
      ...appearance.ansi
    }
  }
}

/**
 * Renders an interactive login shell backed by a main-process node-pty
 * process (see src/plugins/terminal/main/terminal.ts). `node.config.cwd` seeds the pty's
 * working directory (defaults to $HOME, resolved main-side).
 */
export function TerminalRenderer({ node }: ContentRendererProps<LeafContent>) {
  const containerRef = useRef<HTMLDivElement>(null)
  const termRef = useRef<Terminal | null>(null)
  const fitAddonRef = useRef<FitAddon | null>(null)
  const cwd = node.config.cwd as string | undefined
  const enableWebglRendering = useTerminalSetting((settings) => settings.enableWebglRendering)
  const terminalAppearance = useTerminalSetting((settings) => settings.appearance)
  const scrollback = useTerminalSetting((settings) => settings.scrollback)

  // cwd and enableWebglRendering are only meaningful the first time this id
  // is created; a live pty ignores cwd on reattach (see createTerminal in
  // src/plugins/terminal/main/terminal.ts), and an already-open terminal's renderer doesn't
  // hot-swap when the setting changes later — so both are intentionally
  // excluded from the dependency list below.
  // biome-ignore lint/correctness/useExhaustiveDependencies: see above
  useEffect(() => {
    const container = containerRef.current
    if (!container) return

    // Reuses the xterm.js instance (and its on-screen scrollback) from a
    // prior mount of this same id if one is still alive, instead of building
    // a fresh, blank terminal — see terminalRegistry.ts.
    const instance = acquireTerminal(node.id, () => {
      const shadow = document.createElement('div')
      shadow.className = 'terminal-session'
      // Must be attached (and sized) before term.open() measures it.
      container.appendChild(shadow)

      const term = new Terminal({
        ...toXtermOptions(getTerminalSettings().appearance),
        scrollback: getTerminalSettings().scrollback,
        // Handles OSC 8 hyperlinks (the ones tools like gh or eza emit).
        // Deliberately not folded into toXtermOptions: that shape gets
        // re-Object.assign'd onto term.options on every settings change (see
        // the restyle effect below) and this has nothing to do with
        // appearance. Without it xterm falls back to its own confirm()
        // dialog followed by a bare window.open(), which opens nothing.
        // allowNonHttpProtocols stays off, so xterm itself refuses anything
        // but http(s) before activate ever runs.
        linkHandler: { activate: openTerminalLink }
      })
      const fitAddon = new FitAddon()
      term.loadAddon(fitAddon)
      // The other half: linkifies plain-text URLs printed into the scrollback,
      // which xterm core doesn't do on its own. Both kinds of link funnel into
      // the same modifier-gated activate.
      term.loadAddon(new WebLinksAddon(openTerminalLink))
      term.open(shadow)
      // xterm routes keystrokes through a hidden <textarea>, which core's
      // navigation handler would otherwise read as a text field and leave
      // alone — so Cmd/Ctrl+Arrow inside a focused terminal would move the
      // caret's business, not the pane focus. Opt out of that heuristic (see
      // isTextEditingTarget in content/spatialNav.ts). Set through xterm's
      // public `textarea` rather than by hunting its internal CSS class, and
      // set once per instance: the element outlives every remount, since the
      // instance is reattached rather than rebuilt (terminalRegistry.ts).
      term.textarea?.setAttribute('data-nav-text-input', 'false')

      if (enableWebglRendering) {
        try {
          const webglAddon = new WebglAddon()
          // Reverts to the default renderer rather than leaving the pane
          // blank if the GPU context is lost (driver reset, too many
          // concurrent WebGL contexts, etc).
          webglAddon.onContextLoss(() => webglAddon.dispose())
          term.loadAddon(webglAddon)
        } catch {
          // No WebGL2 context available — silently keep the default renderer.
        }
      }

      term.onData((data) => {
        terminalBridge.write(node.id, data)
      })
      term.onBell(() => {
        // Core decides how (and whether) to surface it — the indicator's
        // enablement and "is the user looking at it" gates live in
        // bellStore.ring, and the Dock bounce's focus gate in main.
        terminalCtx.get().bell.ring(node.id)
      })
      // The process's own reported title (OSC 0/2), e.g. the running shell's
      // prompt or a foreground command — see setLiveTitle in tree.ts for how
      // this yields to a manually-set pane title.
      term.onTitleChange((title) => {
        terminalCtx.get().layout.setLiveTitle(node.id, title)
      })
      const unsubscribeData = terminalBridge.onData(node.id, (data) => {
        term.write(data)
      })
      const unsubscribeExit = terminalBridge.onExit(node.id, () => {
        term.write('\r\n\x1b[2m[process exited]\x1b[0m\r\n')
      })

      return { term, fitAddon, container: shadow, unsubscribeData, unsubscribeExit }
    })

    // No-op if this is the instance's first mount (already a child of
    // `container`); re-parents its already-rendered DOM on a remount.
    container.appendChild(instance.container)
    termRef.current = instance.term
    fitAddonRef.current = instance.fitAddon
    // Mounting into a hidden pane (e.g. an inactive tab): skip the fit for
    // the same reason as the ResizeObserver guard below — the observer fires
    // with the real box once the pane is shown.
    if (container.clientWidth > 0 && container.clientHeight > 0) instance.fitAddon.fit()

    let cancelled = false
    terminalBridge
      .create(node.id, cwd, instance.term.cols, instance.term.rows)
      .then((pid) => {
        if (cancelled) return
        // Test/debug-observable only; not read by any app logic.
        container.dataset.ptyPid = String(pid)
      })
      .catch((error) => {
        console.error('[tabs] terminal create failed:', error)
      })

    const resizeObserver = new ResizeObserver((entries) => {
      // 0×0 means the pane just went display:none (an inactive tab), not
      // that it was resized. FitAddon would misread the unlaid-out container
      // as a ~100px box (getComputedStyle returns the specified '100%' and
      // parseInt('100%') === 100) and SIGWINCH the pty down to ~11×6 — any
      // running TUI then repaints its screen at that size while hidden. The
      // observer fires again with the real box when the pane is shown again.
      const box = entries[entries.length - 1]!.contentRect
      if (box.width === 0 || box.height === 0) return
      instance.fitAddon.fit()
      terminalBridge.resize(node.id, instance.term.cols, instance.term.rows)
    })
    resizeObserver.observe(container)

    // Deterministic click-to-focus on the stable container, not xterm's own
    // screen-element handler: a resize (e.g. this pane just un-hiding behind
    // a tab switch) re-renders xterm's rows, and a click landing mid-churn
    // can press on a node that's gone by release — xterm never sees it, and
    // keystrokes silently fall through to nothing.
    const focusOnClick = (): void => instance.term.focus()
    container.addEventListener('click', focusOnClick)

    return () => {
      cancelled = true
      container.removeEventListener('click', focusOnClick)
      resizeObserver.disconnect()
      // Debounced, not immediate: a remount within the grace period (a move,
      // a tab promoting/collapsing, a sibling split changing) reattaches to
      // this same instance instead of tearing it down.
      releaseTerminal(node.id, (dying) => {
        dying.unsubscribeData()
        dying.unsubscribeExit()
        dying.term.dispose()
        void terminalBridge.dispose(node.id)
        terminalCtx.get().bell.clear(node.id)
      })
    }
  }, [node.id])

  // This pane's core handle (see core/registry/paneHandles.ts): how core's
  // focus-follows-active reaches the terminal, and how the Cmd/Ctrl+K menu
  // action (see core's content/paneShortcuts.ts) reaches its live xterm instance —
  // registered separately from the acquire/release effect above so it doesn't
  // participate in that effect's reattach logic, and reading termRef lazily
  // so it keeps resolving as the pane reattaches.
  useEffect(
    () =>
      terminalCtx.get().panes.registerHandle(node.id, {
        focus: () => {
          const term = termRef.current
          if (!term) return
          term.focus()
          // The pane the user is now looking at doesn't need its bell flagged
          // — the counterpart of ring()'s own attended check (bellStore.ts).
          terminalCtx.get().bell.clear(node.id)
        },
        // Only release focus this terminal still holds — by the time a
        // deactivation runs, focus may already belong to the next pane.
        blur: () => {
          const term = termRef.current
          if (term?.textarea && term.textarea === document.activeElement) term.blur()
        },
        extension: {
          clear: () => {
            const term = termRef.current
            if (!term) return
            // Nothing to clear while a full-screen TUI (vim, htop, less) owns
            // the alternate buffer: xterm's clear() collapses whichever buffer
            // is active, so it would wipe the app's rendering while the app
            // still believes it's on screen, and only the region it repaints
            // next would come back.
            if (term.buffer.active.type !== 'normal') return
            term.clear()
          }
        }
      }),
    [node.id]
  )

  // Restyles an already-open pane in place when the user edits terminal
  // settings, instead of only affecting panes opened afterward. xterm.js
  // supports live-mutating `.options` on a running instance — no need to
  // tear down and rebuild the Terminal. fontSize/fontFamily/lineHeight
  // changes shift the pixel size of a cell, so the container's existing
  // pixel box now maps to a different cols/rows; re-fit and push that to the
  // pty, same as the ResizeObserver path above (and guarded the same way
  // against measuring a hidden, display:none container).
  useEffect(() => {
    const term = termRef.current
    const fitAddon = fitAddonRef.current
    const container = containerRef.current
    if (!term || !fitAddon || !container) return
    Object.assign(term.options, toXtermOptions(terminalAppearance))
    // .terminal-container's own padding (and the leftover strip below/right
    // of the last cell once FitAddon floors rows/cols) isn't covered by
    // xterm's canvas — paint it here so it matches instead of showing the
    // pane's ambient background through the gap (see the .xterm-viewport
    // override in src/plugins/terminal/renderer/terminal.css for the other half of this fix).
    container.style.backgroundColor = terminalAppearance.background
    if (container.clientWidth > 0 && container.clientHeight > 0) {
      fitAddon.fit()
      terminalBridge.resize(node.id, term.cols, term.rows)
    }
  }, [terminalAppearance, node.id])

  // Same live-mutation as the restyle effect above, but kept separate: unlike
  // font/line-height, a scrollback change doesn't shift the pixel size of a
  // cell, so there's nothing here to re-fit or push to the pty.
  useEffect(() => {
    const term = termRef.current
    if (!term) return
    term.options.scrollback = scrollback
  }, [scrollback])

  return <div className="terminal-container" data-testid="terminal" ref={containerRef} />
}
