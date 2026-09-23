/**
 * How long a pty whose window has closed waits to be claimed before main
 * kills it (see disposeOrphanedTerminals in main/terminal.ts). A pty in the
 * middle of a cross-window move is still hosted by the window it left until
 * its destination mounts it — or, if the destination refused, until the
 * source's rollback remounts it — so a close landing in that gap must not be
 * taken as the end of the shell the move is carrying. Sized for a slow
 * destination rather than an idle one, since a pty that outlives it is
 * killed and the pane respawns a fresh shell. In shared so the e2e specs
 * that wait it out can import the number.
 */
export const ORPHAN_GRACE_MS = 5000
