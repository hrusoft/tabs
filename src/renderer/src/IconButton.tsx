import type { MouseEventHandler, PointerEventHandler, ReactNode } from 'react'
import { Tooltip } from './Tooltip'

/**
 * An icon-only button with a label — the one place that turns a label into
 * everything such a control owes: its accessible name (`aria-label`), the
 * native `title` (kept as free correctness should the Electron bug described
 * in Tooltip.tsx ever be fixed) and the reliable hover/focus-visible bubble
 * (`Tooltip`). A call site states the label once and cannot half-wire it.
 *
 * Presses are the caller's own: `HeaderButton` adds pane chrome's
 * press-isolation contract on top of this, while the browser toolbar, a tab's
 * close button and the Settings search's Clear button use it bare.
 */
export function IconButton({
  label,
  testId,
  className,
  disabled,
  role,
  onClick,
  onPointerDown,
  children
}: {
  label: string
  testId?: string | undefined
  className?: string | undefined
  disabled?: boolean | undefined
  role?: string | undefined
  onClick?: MouseEventHandler<HTMLButtonElement> | undefined
  onPointerDown?: PointerEventHandler<HTMLButtonElement> | undefined
  children: ReactNode
}): ReactNode {
  return (
    <Tooltip label={label}>
      <button
        type="button"
        className={className}
        data-testid={testId}
        aria-label={label}
        title={label}
        disabled={disabled}
        role={role}
        onPointerDown={onPointerDown}
        onClick={onClick}
      >
        {children}
      </button>
    </Tooltip>
  )
}
