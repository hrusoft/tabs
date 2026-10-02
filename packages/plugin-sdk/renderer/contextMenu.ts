/** One right-click context menu item — the shape `RendererPluginContext.contextMenu.open` takes. */
export interface ContextMenuItem {
  label: string
  onSelect: () => void
}
