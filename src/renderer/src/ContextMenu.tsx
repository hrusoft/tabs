import { useEffect, useRef, useState } from 'react'
import { clampOverlay } from './core/overlayPosition'
import { useContextMenuStore } from './core/store/contextMenuStore'

/**
 * The app's single right-click context menu. Escape and an outside click
 * (the backdrop) both close it, and a click on the menu itself doesn't
 * bubble to the backdrop.
 */
export function ContextMenu() {
  const menu = useContextMenuStore((state) => state.menu)
  const close = useContextMenuStore((state) => state.close)
  const menuRef = useRef<HTMLDivElement>(null)
  const [pos, setPos] = useState<{ left: number; top: number } | null>(null)

  useEffect(() => {
    if (!menu) return
    const onKeyDown = (event: KeyboardEvent): void => {
      if (event.key === 'Escape') close()
    }
    window.addEventListener('keydown', onKeyDown)
    return () => window.removeEventListener('keydown', onKeyDown)
  }, [menu, close])

  // Clamp against the viewport only once the menu's real size is known —
  // sizing it off-screen first would flash at the unclamped position.
  useEffect(() => {
    if (!menu) {
      setPos(null)
      return
    }
    const el = menuRef.current
    if (!el) return
    const { width, height } = el.getBoundingClientRect()
    setPos({
      left: clampOverlay(menu.x, width, window.innerWidth),
      top: clampOverlay(menu.y, height, window.innerHeight)
    })
  }, [menu])

  if (!menu) return null

  return (
    // Backdrop click-to-close, not itself a control — Escape (handled above)
    // is the keyboard equivalent.
    // biome-ignore lint/a11y/noStaticElementInteractions: see above
    // biome-ignore lint/a11y/useKeyWithClickEvents: see above
    <div className="context-menu-backdrop" data-testid="context-menu-backdrop" onClick={close}>
      {/* Swallows the backdrop's onClick so clicks inside the menu don't close it. */}
      {/* biome-ignore lint/a11y/useKeyWithClickEvents: see above */}
      <div
        ref={menuRef}
        className="context-menu"
        role="menu"
        data-testid="context-menu"
        style={pos ? { left: pos.left, top: pos.top } : { left: menu.x, top: menu.y, opacity: 0 }}
        onClick={(event) => event.stopPropagation()}
      >
        {menu.items.map((item) => (
          <button
            key={item.label}
            type="button"
            role="menuitem"
            className="context-menu-item"
            onClick={() => {
              item.onSelect()
              close()
            }}
          >
            {item.label}
          </button>
        ))}
      </div>
    </div>
  )
}
