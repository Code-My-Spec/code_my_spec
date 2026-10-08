import { LiveFlowHook } from "live_flow"

// LiveFlow 0.2.3 fits immediately after sending layout positions, before
// LiveView has patched them. Wait for that patch so the first view fits
// the arranged graph, rather than the temporary vertical stack.
export const StoryFlow = {
  ...LiveFlowHook,
  mounted() {
    // HEEx omits false attributes; this release's hook expects the string
    // "false" to disable editing. Keep this story diagram read-only.
    this.el.dataset.nodesDraggable = "false"
    this.el.dataset.nodesConnectable = "false"
    LiveFlowHook.mounted.call(this)
    const fitView = this.panZoom.fitView.bind(this.panZoom)
    this.panZoom.fitView = (...args) => {
      if (!this.layoutPending) fitView(...args)
    }
  },
  pushNodeChange(changes) {
    if (!changes.length) return
    const layout = changes.some(change => change.type === "position")
    if (layout) this.layoutPending = true
    this.pushEvent("lf:node_change", { changes }, () => {
      if (layout) {
        this.layoutPending = false
        this.panZoom.fitView(0.1, 0)
      }
    })
  },
}
