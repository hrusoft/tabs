import { describe, expect, it } from 'vitest'
import { checkoutTargetLabel, decideCheckout, splitRemoteRef } from '../checkoutTargets'

describe('splitRemoteRef', () => {
  it('splits on the matching configured remote, even when the branch name has slashes of its own', () => {
    expect(splitRemoteRef('origin/feature/x', ['origin'])).toEqual({
      remote: 'origin',
      name: 'feature/x',
      ref: 'origin/feature/x'
    })
  })

  it('prefers the longest matching remote name, so a remote whose own name has a slash still resolves', () => {
    expect(splitRemoteRef('origin/staging/main', ['origin', 'origin/staging'])).toEqual({
      remote: 'origin/staging',
      name: 'main',
      ref: 'origin/staging/main'
    })
  })

  it('falls back to the first path segment when no configured remote matches', () => {
    expect(splitRemoteRef('origin/feature-x', [])).toEqual({
      remote: 'origin',
      name: 'feature-x',
      ref: 'origin/feature-x'
    })
  })

  it('falls back to the whole string as both remote and name when there is no slash at all', () => {
    expect(splitRemoteRef('origin', [])).toEqual({
      remote: 'origin',
      name: 'origin',
      ref: 'origin'
    })
  })
})

describe('decideCheckout', () => {
  it('checks out the one local branch with no prompt', () => {
    expect(decideCheckout(['main'], [], ['main'])).toEqual({
      kind: 'single',
      target: { kind: 'branch', name: 'main' }
    })
  })

  it('prompts among several local branches, never mixing in a remote', () => {
    const decision = decideCheckout(
      ['main', 'stable'],
      [{ remote: 'origin', name: 'main', ref: 'origin/main' }],
      ['main', 'stable']
    )
    expect(decision).toEqual({
      kind: 'choose',
      targets: [
        { kind: 'branch', name: 'main' },
        { kind: 'branch', name: 'stable' }
      ]
    })
  })

  it('ignores remote-tracking branches entirely once any local branch is at the commit — the everyday in-sync case', () => {
    // main and origin/main both at the tip, which is the ordinary state of
    // an unpushed-nothing branch — must not become a spurious two-option prompt.
    const decision = decideCheckout(
      ['main'],
      [{ remote: 'origin', name: 'main', ref: 'origin/main' }],
      ['main']
    )
    expect(decision).toEqual({ kind: 'single', target: { kind: 'branch', name: 'main' } })
  })

  it('falls back to a lone remote-tracking branch when there is no local branch at all', () => {
    const decision = decideCheckout(
      [],
      [{ remote: 'origin', name: 'feature-x', ref: 'origin/feature-x' }],
      ['main']
    )
    expect(decision).toEqual({
      kind: 'single',
      target: {
        kind: 'remote-branch',
        remote: 'origin',
        name: 'feature-x',
        ref: 'origin/feature-x'
      }
    })
  })

  it('prompts among several remote-tracking branches when there is no local branch', () => {
    const decision = decideCheckout(
      [],
      [
        { remote: 'origin', name: 'feature-x', ref: 'origin/feature-x' },
        { remote: 'upstream', name: 'feature-x', ref: 'upstream/feature-x' }
      ],
      ['main']
    )
    expect(decision).toEqual({
      kind: 'choose',
      targets: [
        { kind: 'remote-branch', remote: 'origin', name: 'feature-x', ref: 'origin/feature-x' },
        { kind: 'remote-branch', remote: 'upstream', name: 'feature-x', ref: 'upstream/feature-x' }
      ]
    })
  })

  it('drops a remote-tracking branch whose name collides with an existing local branch anywhere in the repo', () => {
    // "my local is behind its remote": a local `feature` branch exists (just
    // not at this commit), so offering origin/feature here would only fail
    // with "a branch named 'feature' already exists".
    const decision = decideCheckout(
      [],
      [{ remote: 'origin', name: 'feature', ref: 'origin/feature' }],
      ['main', 'feature']
    )
    expect(decision).toEqual({ kind: 'none' })
  })

  it('falls through to none when a collision drops the only remote candidate, even with others left unfiltered', () => {
    const decision = decideCheckout(
      [],
      [
        { remote: 'origin', name: 'feature', ref: 'origin/feature' },
        { remote: 'upstream', name: 'feature', ref: 'upstream/feature' }
      ],
      ['main', 'feature']
    )
    expect(decision).toEqual({ kind: 'none' })
  })

  it('is none when the commit has no local or remote-tracking branch at all', () => {
    expect(decideCheckout([], [], ['main'])).toEqual({ kind: 'none' })
  })
})

describe('checkoutTargetLabel', () => {
  it('labels a branch by its own name', () => {
    expect(checkoutTargetLabel({ kind: 'branch', name: 'main' })).toBe('main')
  })

  it('labels a remote branch by its full ref, so it reads distinctly from a same-named local branch', () => {
    expect(
      checkoutTargetLabel({ kind: 'remote-branch', remote: 'origin', name: 'x', ref: 'origin/x' })
    ).toBe('origin/x')
  })

  it('labels a bare commit target by its hash', () => {
    expect(checkoutTargetLabel({ kind: 'commit', hash: 'abc123' })).toBe('abc123')
  })
})
