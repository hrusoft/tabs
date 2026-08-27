import type { ReactNode } from 'react'

/**
 * The leading attention icon a pane cue renders — the bell on a pane header
 * or a backgrounded tab, the robot on a controlled pane. One component for
 * the three render sites so the markup contract (role="img", lead position,
 * aria-label) is stated once; the pulse and color come from the className's
 * rule in global.css (Bell / Controlled panes sections).
 */
export function CueIcon(props: {
  className: string
  testId: string
  label: string
  /** A hover tooltip, for cues whose icon alone doesn't explain itself. */
  title?: string
  children: ReactNode
}) {
  return (
    <span
      className={props.className}
      role="img"
      data-testid={props.testId}
      aria-label={props.label}
      title={props.title}
    >
      {props.children}
    </span>
  )
}
