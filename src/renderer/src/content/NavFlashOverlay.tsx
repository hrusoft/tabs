import type { NavDirection } from '@shared/model/navigation'
import { useNavFlashStore } from '../core/store/navFlashStore'

const ROTATION: Record<NavDirection, number> = { right: 0, down: 90, left: 180, up: 270 }

/**
 * The brief centered flash showing which way keyboard navigation moved: one
 * chevron rotated per direction. Keyed by nonce so a press mid-fade restarts
 * the animation, and unmounted when the fade ends so no invisible element
 * lingers over the panes.
 */
export function NavFlashOverlay() {
  const flash = useNavFlashStore((state) => state.flash)
  const clear = useNavFlashStore((state) => state.clear)
  if (!flash) return null
  return (
    <div
      key={flash.nonce}
      className="nav-flash"
      data-testid="nav-flash"
      data-direction={flash.direction}
      onAnimationEnd={clear}
    >
      <svg
        viewBox="0 0 24 24"
        aria-hidden="true"
        style={{ transform: `rotate(${ROTATION[flash.direction]}deg)` }}
      >
        <path
          d="M9 5l7 7-7 7"
          fill="none"
          stroke="currentColor"
          strokeWidth="2.5"
          strokeLinecap="round"
          strokeLinejoin="round"
        />
      </svg>
    </div>
  )
}
