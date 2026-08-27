import type { ContentNode } from '@shared/model/types'
import { afterEach, describe, expect, it, vi } from 'vitest'
import {
  installTemporaryContentTypes,
  testLeaf as leaf
} from '../../testing/contentRegistryFixture'
import { confirmClosingContent } from '../closeConfirmation'

const registerContentType = installTemporaryContentTypes()

/** This file's vocabulary — every case here is about whether a type can block a close. */
function registerType(type: string, mayBlockClose?: boolean): void {
  registerContentType({ type, mayBlockClose })
}

afterEach(() => {
  vi.unstubAllGlobals()
})

function stubConfirmClose(answer: boolean): ReturnType<typeof vi.fn> {
  const confirmClose = vi.fn().mockResolvedValue(answer)
  vi.stubGlobal('window', { api: { pane: { confirmClose } } })
  return confirmClose
}

describe('confirmClosingContent', () => {
  it('resolves true for a null node without any IPC', async () => {
    const confirmClose = stubConfirmClose(false)
    await expect(confirmClosingContent(null)).resolves.toBe(true)
    expect(confirmClose).not.toHaveBeenCalled()
  })

  it('resolves true without IPC when no leaf type can block (fast path)', async () => {
    const confirmClose = stubConfirmClose(false)
    registerType('quiet')
    const node: ContentNode = {
      id: 's',
      type: 'split',
      direction: 'horizontal',
      children: [leaf('a', 'quiet'), leaf('b', 'never-registered')],
      sizes: [0.5, 0.5]
    }
    await expect(confirmClosingContent(node)).resolves.toBe(true)
    expect(confirmClose).not.toHaveBeenCalled()
  })

  it('asks main with exactly the blocking leaf ids and returns its answer', async () => {
    const confirmClose = stubConfirmClose(false)
    registerType('blocking', true)
    registerType('quiet')
    const node: ContentNode = {
      id: 's',
      type: 'split',
      direction: 'vertical',
      children: [leaf('a', 'blocking'), leaf('b', 'quiet')],
      sizes: [0.5, 0.5]
    }
    await expect(confirmClosingContent(node)).resolves.toBe(false)
    expect(confirmClose).toHaveBeenCalledExactlyOnceWith(['a'])
  })

  it('collects blocking leaves across nested containers, including inactive tabs', async () => {
    const confirmClose = stubConfirmClose(true)
    registerType('blocking', true)
    const node: ContentNode = {
      id: 'g',
      type: 'tabs',
      activeTabId: 't1',
      tabs: [
        { id: 't1', title: 'active', content: leaf('a', 'blocking') },
        {
          id: 't2',
          title: 'inactive',
          content: {
            id: 's',
            type: 'split',
            direction: 'horizontal',
            children: [leaf('b', 'blocking'), leaf('c', 'blocking')],
            sizes: [0.5, 0.5]
          }
        }
      ]
    }
    await expect(confirmClosingContent(node)).resolves.toBe(true)
    expect(confirmClose).toHaveBeenCalledExactlyOnceWith(['a', 'b', 'c'])
  })
})
