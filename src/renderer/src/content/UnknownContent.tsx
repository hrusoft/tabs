import type { ContentRendererProps } from '../core/registry/registry'

export function UnknownContent({ node }: ContentRendererProps) {
  return (
    <div className="unknown-content">
      <p>
        No renderer registered for content type <code>{node.type}</code>.
      </p>
    </div>
  )
}
