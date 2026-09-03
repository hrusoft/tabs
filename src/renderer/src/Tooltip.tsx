import { type ReactNode, useEffect, useRef, useState } from 'react'
import { createPortal } from 'react-dom'
import { clampOverlay } from './core/overlayPosition'

/**
 * Hover/focus delay before the bubble appears. Fast enough to answer "what
 * does this do?" while exploring the chrome, and — unlike the native `title`
 * tooltip this replaces — actually reliable: macOS Electron 38+ shows a
 * `title` tooltip on the first hover only, rarely on any hover after that
 * (electron/electron#49843, confirmed by a maintainer, no fix as of this
 * app's pinned Electron 43). This component owns the whole interaction
 * instead of asking Chromium's OS-level tooltip pipeline for it.
 */
const SHOW_DELAY_MS = 400

/** Gap kept between the trigger and the bubble, and between the bubble and the window edge. */
const GAP = 6

/**
 * A small hover/focus-visible tooltip for an icon-only quick-action button —
 * the shared replacement for a bare `title` attribute. Wrap the button (or
 * whatever the trigger is) in it:
 *
 *   <Tooltip label="Back"><button aria-label="Back">…</button></Tooltip>
 *
 * `label` is only the tooltip's text — callers keep their own `aria-label`
 * (and may keep `title` too; native support costs nothing extra and the
 * upstream bug above could always be fixed later).
 *
 * Renders through a portal to `document.body` rather than as a normal
 * positioned descendant, specifically so it can never be clipped by an
 * ancestor's `overflow`. `.tab-strip`'s `overflow-x: auto` computes
 * `overflow-y` to `auto` too (see its comment in global.css), which would
 * swallow a tooltip trying to open above or below the tab strip's own "+"
 * button or a tab's close button — both only 24px tall containers, nowhere
 * near enough room for a bubble. Position is measured off the trigger's own
 * box each time it shows, so one implementation serves a nested pane header,
 * a tab strip, a floating window, and the Settings sidebar alike, without
 * each call site doing its own math — the same reason ContextMenu measures
 * itself against the viewport instead of trusting a caller-supplied rect.
 *
 * The wrapper is `display: contents` (see global.css) so it adds no box of
 * its own: inserting a plain element between a button and its flex-container
 * parent would perturb hover-reveal rules and spacing keyed off *direct*
 * children (`.pane-header-controls:hover`, `.tab-bar:hover
 * .tab-strip-new-tab-button`, `.tab`'s own `gap`). `display: contents`
 * removes the wrapper from box generation entirely — the child becomes, for
 * layout purposes, exactly as if it were unwrapped — while it's still a real
 * DOM node, so `mouseenter`/`mouseleave`/`focus`/`blur` on it still fire
 * correctly off the child's actual rendered box.
 *
 * Shown on real mouse hover, and on keyboard focus specifically —
 * `Element.matches(':focus-visible')` is what tells the two apart, so
 * clicking a button (which also focuses it) doesn't leave a redundant
 * tooltip competing with the one hover already showed.
 */
export function Tooltip({ label, children }: { label: string; children: ReactNode }): ReactNode {
  const [anchor, setAnchor] = useState<DOMRect | null>(null)
  const triggerRef = useRef<HTMLSpanElement>(null)
  const showTimer = useRef<ReturnType<typeof setTimeout> | undefined>(undefined)

  const show = (): void => {
    clearTimeout(showTimer.current)
    showTimer.current = setTimeout(() => {
      // Not triggerRef.current.getBoundingClientRect() itself: `display:
      // contents` (see global.css) means the span generates no box of its
      // own, so its own rect is degenerate — measured all-zero in practice,
      // which silently mispositioned every bubble at the viewport's
      // top-left corner until this was caught by a real Chromium hover
      // test (jsdom never renders real layout, so it could not have caught
      // this — see the file-level comment on the browser-tier spec). The
      // wrapper is still a real DOM node despite drawing nothing, so its
      // child element — the actual button — has the real box to measure.
      setAnchor(triggerRef.current?.firstElementChild?.getBoundingClientRect() ?? null)
    }, SHOW_DELAY_MS)
  }

  const hide = (): void => {
    clearTimeout(showTimer.current)
    setAnchor(null)
  }

  // Unmounting mid-delay (a pane closing under the pointer) must not fire a
  // setState on a gone component.
  useEffect(() => () => clearTimeout(showTimer.current), [])

  return (
    // Not itself interactive — like PaneHeaderMenuGroup's own group span,
    // this is a hover/focus *probe* that mirrors whatever's inside it; the
    // real interactive element is the child the caller passed in.
    // biome-ignore lint/a11y/noStaticElementInteractions: see above
    <span
      ref={triggerRef}
      className="tooltip-trigger"
      onMouseEnter={show}
      onMouseLeave={hide}
      onFocus={(event) => {
        if (event.target.matches(':focus-visible')) show()
      }}
      onBlur={hide}
    >
      {children}
      {anchor && createPortal(<TooltipBubble label={label} anchor={anchor} />, document.body)}
    </span>
  )
}

/**
 * The portaled bubble itself. Rendered first at its anchor's own position
 * with `opacity: 0` so its real size can be measured, then repositioned,
 * clamped, and faded in — the same two-pass technique ContextMenu uses for
 * the same reason: sizing it off-screen first would flash at the wrong spot.
 */
function TooltipBubble({ label, anchor }: { label: string; anchor: DOMRect }): ReactNode {
  const bubbleRef = useRef<HTMLDivElement>(null)
  const [pos, setPos] = useState<{ left: number; top: number } | null>(null)

  useEffect(() => {
    const el = bubbleRef.current
    if (!el) return
    const { width, height } = el.getBoundingClientRect()
    const left = clampOverlay(anchor.left + anchor.width / 2 - width / 2, width, window.innerWidth)
    // Below the trigger by default — every current caller sits near the top
    // of its window (a pane header, a tab strip, a toolbar, a settings
    // search field), so "below" is normally the roomier direction. Flips
    // above only when there genuinely isn't GAP + height of room under it.
    const below = anchor.bottom + GAP
    const top =
      below + height + GAP <= window.innerHeight ? below : Math.max(GAP, anchor.top - GAP - height)
    setPos({ left, top })
  }, [anchor])

  return (
    <div
      ref={bubbleRef}
      className="tooltip-bubble"
      role="tooltip"
      data-testid="tooltip-bubble"
      // Positioned but invisible until measured (see above), rather than
      // held out of the DOM: `getBoundingClientRect` needs a real box to
      // measure, and rendering at the trigger's own position first — instead
      // of at {0,0} — keeps that one invisible frame from ever painting
      // somewhere a screenshot mid-test could catch.
      style={
        pos
          ? { left: pos.left, top: pos.top, opacity: 1 }
          : { left: anchor.left, top: anchor.bottom, opacity: 0 }
      }
    >
      {label}
    </div>
  )
}
