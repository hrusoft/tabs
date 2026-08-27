export interface Box {
  x: number
  y: number
  width: number
  height: number
}

/** A locator's bounding box, or a hard failure when it isn't rendered. */
export async function requireBox(locator: { boundingBox(): Promise<Box | null> }): Promise<Box> {
  const box = await locator.boundingBox()
  if (!box) throw new Error('Element has no bounding box')
  return box
}

/** The midpoint of a bounding box — the spot every center-aimed gesture computes. */
export function centerOf(box: { x: number; y: number; width: number; height: number }): {
  x: number
  y: number
} {
  return { x: box.x + box.width / 2, y: box.y + box.height / 2 }
}
