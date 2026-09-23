import { expect, test } from 'vitest'
import type { CaffeinateFlags } from '../../shared/api'
import { argsFor } from '../caffeinateArgs'

/**
 * The flag → argv mapping is pulled into its own module (caffeinateArgs.ts)
 * purely so it can be unit-tested without Electron — caffeinate.ts itself
 * transitively imports the real `electron` package (via ./menu), which has
 * no runtime behind it in a plain Node test. Starting/stopping the real
 * `/usr/bin/caffeinate` and proving the app notices it exit is covered in
 * e2e/caffeinate.spec.ts instead (see its own comment on why a real binary,
 * not a stand-in), including that the real `-w` actually ends the process
 * when its watched pid dies.
 */

const ALL_OFF: CaffeinateFlags = {
  preventDisplaySleep: false,
  preventIdleSleep: false,
  preventDiskSleep: false,
  preventSystemSleep: false,
  declareUserActive: false
}

// An arbitrary, obviously-fake pid — these tests only check it's threaded
// through to `-w` verbatim, never that it's a real process.
const PID = 4242

test('every flag off produces only the mandatory -w <pid>', () => {
  expect(argsFor(ALL_OFF, PID)).toEqual(['-w', '4242'])
})

test('each boolean flag maps to its own caffeinate(8) switch, ahead of -w', () => {
  expect(argsFor({ ...ALL_OFF, preventDisplaySleep: true }, PID)).toEqual(['-d', '-w', '4242'])
  expect(argsFor({ ...ALL_OFF, preventIdleSleep: true }, PID)).toEqual(['-i', '-w', '4242'])
  expect(argsFor({ ...ALL_OFF, preventDiskSleep: true }, PID)).toEqual(['-m', '-w', '4242'])
  expect(argsFor({ ...ALL_OFF, preventSystemSleep: true }, PID)).toEqual(['-s', '-w', '4242'])
  expect(argsFor({ ...ALL_OFF, declareUserActive: true }, PID)).toEqual(['-u', '-w', '4242'])
})

test('flags combine in the order the dialog lists them: -d -i -m -s -u, then -w', () => {
  expect(
    argsFor(
      {
        preventDisplaySleep: true,
        preventIdleSleep: true,
        preventDiskSleep: true,
        preventSystemSleep: true,
        declareUserActive: true
      },
      PID
    )
  ).toEqual(['-d', '-i', '-m', '-s', '-u', '-w', '4242'])
})

test('a positive integer timer becomes -t <seconds>, after every flag and before -w', () => {
  expect(argsFor({ ...ALL_OFF, preventDisplaySleep: true, timerSeconds: 300 }, PID)).toEqual([
    '-d',
    '-t',
    '300',
    '-w',
    '4242'
  ])
})

test('an absent timer omits -t entirely — that is what "run until Decaf" means', () => {
  expect(argsFor(ALL_OFF, PID)).not.toContain('-t')
})

test('a non-positive or non-integer timer is treated the same as absent, defensively', () => {
  expect(argsFor({ ...ALL_OFF, timerSeconds: 0 }, PID)).toEqual(['-w', '4242'])
  expect(argsFor({ ...ALL_OFF, timerSeconds: -5 }, PID)).toEqual(['-w', '4242'])
  expect(argsFor({ ...ALL_OFF, timerSeconds: 1.5 }, PID)).toEqual(['-w', '4242'])
})

test('-w always carries the watched pid, never the flags-derived args', () => {
  expect(argsFor(ALL_OFF, 1)).toEqual(['-w', '1'])
  expect(argsFor(ALL_OFF, 99999)).toEqual(['-w', '99999'])
})
