// Deliberately import-free: the settings window reaches this file through
// TerminalSettingsPage.tsx, and must never pull in xterm that way.
export function TerminalIcon() {
  return (
    <svg viewBox="0 0 16 16" width="16" height="16" aria-hidden="true">
      <rect x="1.5" y="2.5" width="13" height="11" rx="1.5" fill="none" stroke="currentColor" />
      <path
        d="M4.5 6l2.5 2-2.5 2M8.5 10h3"
        fill="none"
        stroke="currentColor"
        strokeWidth="1.2"
        strokeLinecap="round"
        strokeLinejoin="round"
      />
    </svg>
  )
}
