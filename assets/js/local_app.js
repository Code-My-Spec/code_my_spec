// Local web LiveView setup (port 4003, localhost only)
import {Socket} from "phoenix"
import {LiveSocket} from "phoenix_live_view"
// graphology + sigma loaded via script tags in root layout (UMD globals)

let Hooks = {}

Hooks.Mermaid = {
  mounted() {
    this.renderGraph()
  },
  updated() {
    this.renderGraph()
  },
  renderGraph() {
    const src = this.el.dataset.graph
    if (!src) return

    // Load mermaid from CDN if not already loaded
    if (window.mermaid) {
      this.doRender(src)
    } else {
      const script = document.createElement("script")
      script.type = "module"
      script.textContent = `
        import mermaid from 'https://cdn.jsdelivr.net/npm/mermaid@11/dist/mermaid.esm.min.mjs';
        mermaid.initialize({
          startOnLoad: false,
          theme: 'dark',
          flowchart: { useMaxWidth: false, htmlLabels: true, curve: 'basis' },
          themeVariables: {
            darkMode: true,
            background: '#0f172a',
            primaryColor: '#1e293b',
            primaryTextColor: '#e2e8f0',
            primaryBorderColor: '#475569',
            lineColor: '#94a3b8'
          }
        });
        window.mermaid = mermaid;
        window.dispatchEvent(new Event('mermaid:loaded'));
      `
      document.head.appendChild(script)
      window.addEventListener('mermaid:loaded', () => this.doRender(src), {once: true})
    }
  },
  async doRender(src) {
    const container = this.el
    try {
      const {svg} = await window.mermaid.render('mermaid-svg', src)
      container.innerHTML = svg
    } catch (e) {
      container.innerHTML = `<pre class="text-red-400">Mermaid render error: ${e.message}</pre><pre>${src}</pre>`
    }
  }
}

Hooks.SigmaGraph = {
  mounted() {
    this.renderGraph()
  },
  updated() {
    if (this.sigma) {
      this.sigma.kill()
      this.sigma = null
    }
    this.renderGraph()
  },
  destroyed() {
    if (this.sigma) {
      this.sigma.kill()
      this.sigma = null
    }
  },
  renderGraph() {
    const raw = this.el.dataset.graph
    if (!raw) return

    const data = JSON.parse(raw)
    const graph = new window.graphology.Graph()

    // Add nodes (skip duplicates — shared components across stories)
    data.nodes.forEach(n => {
      if (!graph.hasNode(n.key)) {
        graph.addNode(n.key, n.attributes)
      }
    })

    // Add edges (deduplicate by key — shared components across stories)
    const seenEdges = new Set()
    data.edges.forEach(e => {
      if (!seenEdges.has(e.key) && graph.hasNode(e.source) && graph.hasNode(e.target)) {
        seenEdges.add(e.key)
        graph.addEdge(e.source, e.target, e.attributes)
      }
    })

    // Render
    const container = this.el
    const SigmaClass = window.Sigma?.default || window.Sigma
    this.sigma = new SigmaClass(graph, container, {
      renderLabels: true,
      labelColor: { color: "#e2e8f0" },
      labelFont: "Inter, system-ui, sans-serif",
      labelSize: 16,
      labelWeight: "bold",
      defaultEdgeType: "arrow",
      defaultEdgeColor: "#64748b",
      stagePadding: 80,
      labelRenderedSizeThreshold: 0,
      labelDensity: 0.5,
      labelGridCellSize: 200,
      zoomToSizeRatioFunction: () => 1,
      itemSizesReference: "positions",
      defaultNodeColor: "#64748b",
    })

    // Zoom out a bit from the default auto-fit so nodes have breathing room
    const camera = this.sigma.getCamera()
    camera.setState({ ratio: 1.3 })

    // Click → navigate to requirement detail
    this.sigma.on("clickNode", ({ node }) => {
      const attrs = graph.getNodeAttributes(node)
      if (attrs.entity_type && attrs.name) {
        this.pushEvent("node_clicked", { name: attrs.name, entity_type: attrs.entity_type })
      } else if (attrs.entity_type === "story" && attrs.entity_id) {
        this.pushEvent("node_clicked", { entity_type: "story", entity_id: attrs.entity_id })
      }
    })

    // Hover cursor
    this.sigma.on("enterNode", () => { container.style.cursor = "pointer" })
    this.sigma.on("leaveNode", () => { container.style.cursor = "default" })
  }
}

let csrfToken = document.querySelector("meta[name='csrf-token']")?.getAttribute("content")
let liveSocket = new LiveSocket("/local-live", Socket, {
  params: {_csrf_token: csrfToken},
  hooks: Hooks
})

liveSocket.connect()
window.liveSocket = liveSocket
