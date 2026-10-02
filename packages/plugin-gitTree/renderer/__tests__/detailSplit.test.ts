import { describe, expect, it } from 'vitest'
import {
  DEFAULT_DETAIL_FRACTION,
  DETAIL_MIN_HEIGHT,
  type DetailSplit,
  LIST_MIN_HEIGHT,
  readDetailSplit,
  resolveDetailDrag
} from '../detailSplit'

describe('readDetailSplit', () => {
  it('gives an untouched pane the fixed 60/40 it always had, open', () => {
    expect(readDetailSplit({})).toEqual({ fraction: 0.4, collapsed: false })
    expect(DEFAULT_DETAIL_FRACTION).toBe(0.4)
  })

  it('reads a saved fraction and collapsed state', () => {
    expect(readDetailSplit({ detailFraction: 0.25, detailCollapsed: true })).toEqual({
      fraction: 0.25,
      collapsed: true
    })
  })

  it.each([
    ['NaN', Number.NaN],
    ['zero', 0],
    ['the whole body', 1],
    ['negative', -0.3],
    ['more than the body', 1.5],
    ['infinite', Number.POSITIVE_INFINITY],
    ['a string', '0.3'],
    ['null', null]
  ])('falls back to the default for a fraction that is %s', (_label, detailFraction) => {
    expect(readDetailSplit({ detailFraction }).fraction).toBe(DEFAULT_DETAIL_FRACTION)
  })

  it('treats anything but a literal true as open', () => {
    expect(readDetailSplit({ detailCollapsed: 'true' }).collapsed).toBe(false)
    expect(readDetailSplit({ detailCollapsed: 1 }).collapsed).toBe(false)
  })
})

describe('resolveDetailDrag', () => {
  const open: DetailSplit = { fraction: 0.4, collapsed: false }

  it('gives the details what the drag asks for, as a share of the body', () => {
    expect(resolveDetailDrag(250, 1000, open)).toEqual({ fraction: 0.25, collapsed: false })
  })

  it('collapses below half the minimum, remembering the last open size', () => {
    expect(resolveDetailDrag(DETAIL_MIN_HEIGHT / 2 - 1, 1000, open)).toEqual({
      fraction: 0.4,
      collapsed: true
    })
    expect(resolveDetailDrag(-50, 1000, open).collapsed).toBe(true)
  })

  it('holds at the minimum between half of it and all of it', () => {
    expect(resolveDetailDrag(DETAIL_MIN_HEIGHT / 2, 1000, open)).toEqual({
      fraction: DETAIL_MIN_HEIGHT / 1000,
      collapsed: false
    })
    expect(resolveDetailDrag(DETAIL_MIN_HEIGHT - 1, 1000, open).fraction).toBe(
      DETAIL_MIN_HEIGHT / 1000
    )
  })

  it('reopens a collapsed panel once dragged back past half the minimum', () => {
    const collapsed: DetailSplit = { fraction: 0.4, collapsed: true }
    expect(resolveDetailDrag(300, 1000, collapsed)).toEqual({ fraction: 0.3, collapsed: false })
  })

  it('never squeezes the commit list below its minimum', () => {
    expect(resolveDetailDrag(990, 1000, open).fraction).toBe((1000 - LIST_MIN_HEIGHT) / 1000)
  })

  it('keeps the details at their minimum in a body too short for both, never a fraction a reload would refuse', () => {
    const split = resolveDetailDrag(100, 80, open)
    expect(split.collapsed).toBe(false)
    expect(split.fraction).toBeGreaterThan(0)
    expect(split.fraction).toBeLessThan(1)
    expect(readDetailSplit({ detailFraction: split.fraction }).fraction).toBe(split.fraction)
  })

  it('changes nothing for a body with no height', () => {
    expect(resolveDetailDrag(10, 0, open)).toBe(open)
  })
})
