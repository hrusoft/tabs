import { describe, expect, it } from 'vitest'
import { ARIA_ROLES, roleFilterError } from '../ariaRoles'

describe('roleFilterError', () => {
  it('accepts every role roleFor can derive, whatever the case', () => {
    // pageScripts.ts's roleFor derives exactly these from tags; a role it can
    // produce must never be refused.
    for (const role of ['link', 'button', 'combobox', 'textbox', 'heading', 'checkbox', 'radio']) {
      expect(roleFilterError(role), role).toBeUndefined()
    }
    for (const role of ['slider', 'generic', 'Button', 'COMBOBOX']) {
      expect(roleFilterError(role), role).toBeUndefined()
    }
  })

  it('accepts the ARIA roles pages set explicitly, module roles included', () => {
    for (const role of ['group', 'switch', 'menuitemcheckbox', 'tab', 'dialog', 'searchbox']) {
      expect(roleFilterError(role), role).toBeUndefined()
    }
    expect(roleFilterError('doc-chapter')).toBeUndefined()
    expect(roleFilterError('graphics-document')).toBeUndefined()
    // A bare prefix is not a role.
    expect(roleFilterError('doc-')).toContain('unknown role')
  })

  it('refuses a name that is not a role, listing the vocabulary', () => {
    const error = roleFilterError('nonsense')
    expect(error).toContain('unknown role "nonsense"')
    for (const role of ARIA_ROLES) expect(error).toContain(role)
    // The tag, not its role — the mistake this most often catches.
    expect(roleFilterError('select')).toContain('unknown role "select"')
  })
})
