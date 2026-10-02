/**
 * How long a released UI instance (a kept-alive xterm, a `<webview>`)
 * survives before real disposal — long enough to absorb the unmount/remount
 * pulse of a structural move, short enough that a genuinely closed pane's
 * resources don't linger. Lives in shared rather than beside the registry
 * (renderer/src/content/reattachRegistry.ts, which re-exports it) so the e2e
 * specs that wait it out (2×) can import the number without dragging a
 * renderer module into the node tsconfig project.
 */
export const REATTACH_GRACE_MS = 300
