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
      hoverRenderer: (context, data, settings) => {
        const size = data.size + 4
        const label = data.label || ""
        context.font = `bold 14px Inter, system-ui, sans-serif`
        const textWidth = context.measureText(label).width
        const padding = 6
        const boxWidth = textWidth + padding * 2
        const boxHeight = 20

        // Dark background with high-contrast white text
        context.fillStyle = "#1e293b"
        context.strokeStyle = "#60a5fa"
        context.lineWidth = 1.5
        context.fillRect(data.x - boxWidth / 2, data.y - size - boxHeight - 4, boxWidth, boxHeight)
        context.strokeRect(data.x - boxWidth / 2, data.y - size - boxHeight - 4, boxWidth, boxHeight)

        context.fillStyle = "#ffffff"
        context.textAlign = "center"
        context.textBaseline = "middle"
        context.fillText(label, data.x, data.y - size - boxHeight / 2 - 4)
      },
      defaultEdgeType: "arrow",
      defaultEdgeColor: "#64748b",
      stagePadding: 80,
      labelRenderedSizeThreshold: 0,
      labelDensity: 0.5,
      labelGridCellSize: 200,
      zoomToSizeRatioFunction: () => 1,
      itemSizesReference: "positions",
      defaultNodeColor: "#64748b",
      enableEdgeClickEvents: true,
      enableEdgeHoverEvents: true,
    })

    // Run simple force layout if requested
    if (data.layout === "force") {
      this.runForceLayout(graph)
    }

    // Zoom out a bit from the default auto-fit so nodes have breathing room
    const camera = this.sigma.getCamera()
    camera.setState({ ratio: 1.3 })

    // Debug panel — dump full graph data
    console.log("Graph data:", data)
    let debugPanel = document.getElementById("graph-debug")
    if (!debugPanel) {
      debugPanel = document.createElement("details")
      debugPanel.id = "graph-debug"
      debugPanel.style.cssText = "position:fixed;bottom:0;left:0;right:0;max-height:50vh;overflow-y:auto;background:#1e293b;color:#e2e8f0;padding:8px 16px;font-family:monospace;font-size:11px;z-index:9999;border-top:2px solid #475569;"
      debugPanel.innerHTML = `<summary style="cursor:pointer;color:#94a3b8;margin-bottom:8px">Graph Debug (${data.nodes.length} nodes, ${data.edges.length} edges)</summary><pre id="graph-debug-content" style="margin:0"></pre>`
      document.body.appendChild(debugPanel)
    }
    const debugContent = document.getElementById("graph-debug-content")
    const edgeList = data.edges.map(e => `${e.source}  →  ${e.target}`).join("\n")
    debugContent.textContent = `EDGES:\n${edgeList}\n\nNODES:\n${data.nodes.map(n => `${n.key}  (${n.attributes.label})`).join("\n")}`

    // Click → show node edges
    this.sigma.on("clickNode", ({ node }) => {
      const attrs = graph.getNodeAttributes(node)
      const inEdges = []
      const outEdges = []

      graph.forEachEdge((edge, edgeAttrs, source, target) => {
        if (target === node) inEdges.push({ edge, from: source })
        if (source === node) outEdges.push({ edge, to: target })
      })

      let panel = document.getElementById("graph-debug")
      if (!panel) {
        panel = document.createElement("div")
        panel.id = "graph-debug"
        panel.style.cssText = "position:fixed;bottom:0;left:0;right:0;max-height:40vh;overflow-y:auto;background:#1e293b;color:#e2e8f0;padding:12px 16px;font-family:monospace;font-size:12px;z-index:9999;border-top:2px solid #475569;"
        document.body.appendChild(panel)
      }

      const inHtml = inEdges.map(e => `  ← ${e.from}`).join("\n")
      const outHtml = outEdges.map(e => `  → ${e.to}`).join("\n")

      panel.innerHTML = `<pre style="margin:0"><strong>${node}</strong>  (${attrs.label || ""})
<span style="color:#60a5fa">IN (${inEdges.length}):</span>
${inHtml || "  (none)"}
<span style="color:#4ade80">OUT (${outEdges.length}):</span>
${outHtml || "  (none)"}</pre>`
    })

    // Click edge → show edge details
    this.sigma.on("clickEdge", ({ edge }) => {
      const source = graph.source(edge)
      const target = graph.target(edge)
      const sourceLabel = graph.getNodeAttributes(source).label || source
      const targetLabel = graph.getNodeAttributes(target).label || target

      let panel = document.getElementById("graph-debug")
      if (!panel) return
      panel.open = true
      const content = document.getElementById("graph-debug-content")
      content.textContent = `EDGE: ${edge}\n\n  FROM: ${source}\n        (${sourceLabel})\n\n  TO:   ${target}\n        (${targetLabel})`
    })

    // Hover cursor
    this.sigma.on("enterNode", () => { container.style.cursor = "pointer" })
    this.sigma.on("leaveNode", () => { container.style.cursor = "default" })
    this.sigma.on("enterEdge", () => { container.style.cursor = "pointer" })
    this.sigma.on("leaveEdge", () => { container.style.cursor = "default" })
  },
  runForceLayout(graph) {
    // Simple spring-electric force layout — runs 200 iterations
    const iterations = 300
    const repulsion = 50000
    const attraction = 0.005
    const damping = 0.85

    const nodes = graph.nodes()
    const vel = {}
    nodes.forEach(n => { vel[n] = { vx: 0, vy: 0 } })

    for (let i = 0; i < iterations; i++) {
      // Repulsion between all node pairs
      for (let a = 0; a < nodes.length; a++) {
        const na = nodes[a]
        const pa = graph.getNodeAttributes(na)
        for (let b = a + 1; b < nodes.length; b++) {
          const nb = nodes[b]
          const pb = graph.getNodeAttributes(nb)
          const dx = pa.x - pb.x
          const dy = pa.y - pb.y
          const dist = Math.sqrt(dx * dx + dy * dy) || 1
          const force = repulsion / (dist * dist)
          const fx = (dx / dist) * force
          const fy = (dy / dist) * force
          vel[na].vx += fx
          vel[na].vy += fy
          vel[nb].vx -= fx
          vel[nb].vy -= fy
        }
      }

      // Attraction along edges
      graph.forEachEdge((edge, attrs, source, target) => {
        const pa = graph.getNodeAttributes(source)
        const pb = graph.getNodeAttributes(target)
        const dx = pb.x - pa.x
        const dy = pb.y - pa.y
        const dist = Math.sqrt(dx * dx + dy * dy) || 1
        const force = dist * attraction
        const fx = (dx / dist) * force
        const fy = (dy / dist) * force
        vel[source].vx += fx
        vel[source].vy += fy
        vel[target].vx -= fx
        vel[target].vy -= fy
      })

      // Apply velocities with damping
      nodes.forEach(n => {
        vel[n].vx *= damping
        vel[n].vy *= damping
        const attrs = graph.getNodeAttributes(n)
        graph.setNodeAttribute(n, "x", attrs.x + vel[n].vx)
        graph.setNodeAttribute(n, "y", attrs.y + vel[n].vy)
      })
    }

    this.sigma.refresh()
  }
}

let csrfToken = document.querySelector("meta[name='csrf-token']")?.getAttribute("content")
let liveSocket = new LiveSocket("/local-live", Socket, {
  params: {_csrf_token: csrfToken},
  hooks: Hooks
})

liveSocket.connect()
window.liveSocket = liveSocket
