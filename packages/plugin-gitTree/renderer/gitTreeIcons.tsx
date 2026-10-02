/**
 * The git tree pane's icons. Import-free like the terminal's, and drawn on the
 * same 16x16 grid with `currentColor` strokes as every other icon here, so
 * they inherit hover/active chrome colours with no rules of their own.
 */

/** Two commits on a branch that diverges — the shape the pane draws, at icon size. */
export function GitTreeIcon() {
  return (
    <svg viewBox="0 0 16 16" width="16" height="16" aria-hidden="true">
      <path
        d="M5 3.6v8.8M5 7.5h3.2a2 2 0 0 0 2-2V4.6"
        fill="none"
        stroke="currentColor"
        strokeWidth="1.2"
        strokeLinecap="round"
      />
      <circle cx="5" cy="2.6" r="1.6" fill="none" stroke="currentColor" strokeWidth="1.1" />
      <circle cx="5" cy="13.4" r="1.6" fill="none" stroke="currentColor" strokeWidth="1.1" />
      <circle cx="10.2" cy="3.6" r="1.6" fill="none" stroke="currentColor" strokeWidth="1.1" />
    </svg>
  )
}

/** An open folder — the browse button. */
export function FolderIcon() {
  return (
    <svg viewBox="0 0 16 16" width="16" height="16" aria-hidden="true">
      <path
        d="M1.8 12.5V4a1 1 0 0 1 1-1h3.1l1.4 1.6h5.9a1 1 0 0 1 1 1v1.1"
        fill="none"
        stroke="currentColor"
        strokeWidth="1.1"
        strokeLinecap="round"
        strokeLinejoin="round"
      />
      <path
        d="M1.8 12.5l1.8-5.2h11.1l-1.8 5.2z"
        fill="none"
        stroke="currentColor"
        strokeWidth="1.1"
        strokeLinejoin="round"
      />
    </svg>
  )
}
