import type { CaffeinateFlags } from '../shared/api'

/**
 * `caffeinate(8)`'s own flags, in the order the dialog lists them, plus a
 * mandatory `-w <watchPid>`: this app's own crash-safety backstop.
 * `before-quit` kills the process on the *prompt* path (a normal quit), but a
 * crash or a SIGKILL never runs `before-quit` at all — without `-w`, an
 * orphaned caffeinate would keep the Mac awake forever, which is exactly the
 * outcome the ticket rules out. `caffeinate` itself exits the moment the
 * watched pid does (confirmed: `-w` composes with `-t`, whichever fires
 * first ends the process), so this is a second, independent way for the
 * process to end besides the app's own kill calls.
 *
 * Its own module, with no import of anything that touches Electron, purely so
 * it can be unit-tested in the "unit" vitest project (caffeinateArgs.test.ts):
 * the rest of caffeinate.ts pulls in `./menu` (for `applyMenu`), which
 * transitively imports the real `electron` package — fine for the real app,
 * fatal for a plain Node test run, which has no Electron runtime behind that
 * import.
 */
export function argsFor(flags: CaffeinateFlags, watchPid: number): string[] {
  const args: string[] = []
  if (flags.preventDisplaySleep) args.push('-d')
  if (flags.preventIdleSleep) args.push('-i')
  if (flags.preventDiskSleep) args.push('-m')
  if (flags.preventSystemSleep) args.push('-s')
  if (flags.declareUserActive) args.push('-u')
  const timer = flags.timerSeconds
  if (timer !== undefined && Number.isInteger(timer) && timer > 0) {
    args.push('-t', String(timer))
  }
  args.push('-w', String(watchPid))
  return args
}
