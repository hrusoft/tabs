export function NewTabIcon() {
  return (
    <svg viewBox="0 0 16 16" width="16" height="16" aria-hidden="true">
      {/* Same 13×11 footprint as SplitHorizontalIcon/SplitVerticalIcon/
          WrapWindowIcon, not the shorter 13×9 this used to be — icons that
          fill less of their own viewBox read as smaller even when the outer
          SVG box is the same 13px everywhere else in the toolbar/menu. */}
      <rect x="1.5" y="2.5" width="13" height="11" rx="1.5" fill="none" stroke="currentColor" />
      <path
        d="M8 6v4M6 8h4"
        fill="none"
        stroke="currentColor"
        strokeWidth="1.2"
        strokeLinecap="round"
      />
    </svg>
  )
}

/** A bare "+", no border — for the tab strip's own always-visible new-tab
 *  button, which sits among tab titles rather than in a boxed toolbar, so it
 *  reads better as a plain glyph than as a small icon-in-a-frame. Thicker
 *  stroke than NewTabIcon's inner cross since it has no rect to set it off
 *  from the background. */
export function PlusIcon() {
  return (
    <svg viewBox="0 0 16 16" width="16" height="16" aria-hidden="true">
      <path
        d="M8 3.5v9M3.5 8h9"
        fill="none"
        stroke="currentColor"
        strokeWidth="2"
        strokeLinecap="round"
      />
    </svg>
  )
}

export function SplitHorizontalIcon() {
  return (
    <svg viewBox="0 0 16 16" width="16" height="16" aria-hidden="true">
      <rect x="1.5" y="2.5" width="5.5" height="11" rx="1" fill="none" stroke="currentColor" />
      <rect x="9" y="2.5" width="5.5" height="11" rx="1" fill="none" stroke="currentColor" />
    </svg>
  )
}

export function SplitVerticalIcon() {
  return (
    <svg viewBox="0 0 16 16" width="16" height="16" aria-hidden="true">
      <rect x="2.5" y="1.5" width="11" height="5.5" rx="1" fill="none" stroke="currentColor" />
      <rect x="2.5" y="9" width="11" height="5.5" rx="1" fill="none" stroke="currentColor" />
    </svg>
  )
}

/** A window escaping its own corner — reads as "opens detached/floating"
 *  rather than docked, the same visual language as a browser's "open link in
 *  new window." */
export function NewUnpinnedTabIcon() {
  return (
    <svg viewBox="0 0 16 16" width="16" height="16" aria-hidden="true">
      <path
        d="M7 3H3.5A1.5 1.5 0 0 0 2 4.5v8A1.5 1.5 0 0 0 3.5 14h8a1.5 1.5 0 0 0 1.5-1.5V9"
        fill="none"
        stroke="currentColor"
        strokeLinecap="round"
        strokeLinejoin="round"
      />
      <path
        d="M9.5 2H14v4.5M14 2 8 8"
        fill="none"
        stroke="currentColor"
        strokeLinecap="round"
        strokeLinejoin="round"
      />
    </svg>
  )
}

export function ClearPaneIcon() {
  return (
    <svg viewBox="0 0 16 16" width="16" height="16" aria-hidden="true">
      {/* An eraser, angled — the diagonal stroke across its face is the worn
          edge, not a slash/prohibition mark. Sized to the same ~12.5×12.5
          footprint as the other menu icons — the original shape was scaled
          down inside its own 16×16 box, reading as noticeably smaller. */}
      <path
        d="M11 1 14.5 4.5 6 13.5H2V10Z"
        fill="none"
        stroke="currentColor"
        strokeLinejoin="round"
      />
      <path d="M9 4 12.5 7.5" stroke="currentColor" strokeLinecap="round" />
    </svg>
  )
}

export function ClosePaneIcon() {
  return (
    <svg viewBox="0 0 16 16" width="16" height="16" aria-hidden="true">
      {/* Same reasoning as ClearPaneIcon: widened from a 9×9 span to 11×11
          (plus a touch more stroke weight) so a pair of thin diagonal lines
          doesn't read as lighter/smaller than the filled-rect icons around
          it in the menu. */}
      <path
        d="M2.5 2.5 13.5 13.5M13.5 2.5 2.5 13.5"
        stroke="currentColor"
        strokeWidth="1.4"
        strokeLinecap="round"
      />
    </svg>
  )
}

export function SettingsIcon() {
  return (
    <svg viewBox="0 0 16 16" width="16" height="16" aria-hidden="true">
      {/* A ring (thick-stroked circle) with eight solid teeth overlapping its
          outer edge, rotated around the center — a cog, not a sun/asterisk. */}
      <circle cx="8" cy="8" r="3.4" fill="none" stroke="currentColor" strokeWidth="2" />
      {[0, 45, 90, 135, 180, 225, 270, 315].map((angle) => (
        <rect
          key={angle}
          x="7.3"
          y="1"
          width="1.4"
          height="3.6"
          fill="currentColor"
          transform={`rotate(${angle} 8 8)`}
        />
      ))}
    </svg>
  )
}

export function WrapWindowIcon() {
  return (
    <svg viewBox="0 0 16 16" width="16" height="16" aria-hidden="true">
      <rect x="1.5" y="2.5" width="13" height="11" rx="1.5" fill="none" stroke="currentColor" />
      <rect x="2.5" y="3.5" width="5" height="2.5" rx="0.5" fill="currentColor" opacity="0.4" />
      <line x1="1.5" y1="6.5" x2="14.5" y2="6.5" stroke="currentColor" strokeWidth="1" />
    </svg>
  )
}

export function SkillIcon() {
  return (
    <svg viewBox="0 0 16 16" width="16" height="16" aria-hidden="true">
      <path
        d="M8 2 9 6.5 13 8 9 9.5 8 14 7 9.5 3 8 7 6.5Z"
        fill="none"
        stroke="currentColor"
        strokeLinejoin="round"
        strokeLinecap="round"
      />
    </svg>
  )
}

export function BellIcon() {
  return (
    <svg viewBox="0 0 16 16" width="16" height="16" aria-hidden="true">
      <path
        d="M8 2.5c-2 0-3 1.6-3 4v1.3c0 .9-.3 1.7-.9 2.4l-.6.7h9l-.6-.7c-.6-.7-.9-1.5-.9-2.4V6.5c0-2.4-1-4-3-4z"
        fill="none"
        stroke="currentColor"
        strokeWidth="1.2"
        strokeLinecap="round"
        strokeLinejoin="round"
      />
      <path
        d="M6.5 12.3a1.5 1.5 0 0 0 3 0"
        fill="none"
        stroke="currentColor"
        strokeWidth="1.2"
        strokeLinecap="round"
      />
    </svg>
  )
}

export function RobotIcon() {
  return (
    <svg viewBox="0 0 16 16" width="16" height="16" aria-hidden="true">
      {/* A rounded-square head with an antenna and two eyes — reads as
          "automated" at 16px without needing a full body, the same
          reasoning as BellIcon staying a bell rather than a full alarm
          clock. */}
      <circle cx="8" cy="1" r="1" fill="currentColor" />
      <path d="M8 2v1.5" stroke="currentColor" strokeWidth="1.2" strokeLinecap="round" />
      <rect
        x="2.5"
        y="3.5"
        width="11"
        height="9"
        rx="2"
        fill="none"
        stroke="currentColor"
        strokeWidth="1.2"
      />
      <circle cx="5.7" cy="8" r="1.1" fill="currentColor" />
      <circle cx="10.3" cy="8" r="1.1" fill="currentColor" />
      <path d="M5.5 10.8h5" stroke="currentColor" strokeWidth="1.2" strokeLinecap="round" />
    </svg>
  )
}

export function KeyboardIcon() {
  return (
    <svg viewBox="0 0 16 16" width="16" height="16" aria-hidden="true">
      {/* A key deck: rounded outer case, two rows of keycaps, and a wide
          spacebar — reads as a keyboard at 16px, where individual keys would
          just be noise. */}
      <rect
        x="1.2"
        y="3.8"
        width="13.6"
        height="8.4"
        rx="1.6"
        fill="none"
        stroke="currentColor"
        strokeWidth="1.2"
      />
      <rect x="3.3" y="6" width="1.5" height="1.5" fill="currentColor" />
      <rect x="6" y="6" width="1.5" height="1.5" fill="currentColor" />
      <rect x="8.7" y="6" width="1.5" height="1.5" fill="currentColor" />
      <rect x="11.4" y="6" width="1.5" height="1.5" fill="currentColor" />
      <rect x="3.3" y="9" width="9.6" height="1.5" rx="0.6" fill="currentColor" />
    </svg>
  )
}
