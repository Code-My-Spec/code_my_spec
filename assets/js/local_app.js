// Local web LiveView setup (port 4003, localhost only)
import {Socket} from "phoenix"
import {LiveSocket} from "phoenix_live_view"
import {hooks as colocatedHooks} from "phoenix-colocated/code_my_spec"
import Sortable from "../vendor/Sortable.min.js"

// Colocated hooks defined in local LiveViews (`:type={Phoenix.LiveView.ColocatedHook}`)
// were never registered here, so every one of them — including the story
// scheduler's drag-and-drop — was dead on the local app. Sortable is exposed
// globally because those hooks reach for `window.Sortable`.
window.Sortable = Sortable
// graphology + sigma loaded via script tags in root layout (UMD globals)

function themeVar(name) {
  return getComputedStyle(document.documentElement).getPropertyValue(name).trim()
}

// Sigma's WebGL renderer only understands hex/rgb — daisyUI themes use oklch().
// Modern Chrome's fillStyle getter preserves the oklch color space, so we have
// to actually paint a pixel and read the resolved RGB back out.
let _normCanvas = null
function normalizeColor(c, fallback = "#64748b") {
  if (!c) return fallback
  const trimmed = String(c).trim()
  if (/^#[0-9a-f]{3,8}$/i.test(trimmed)) return trimmed
  if (!_normCanvas) {
    _normCanvas = document.createElement("canvas")
    _normCanvas.width = 1
    _normCanvas.height = 1
  }
  const ctx = _normCanvas.getContext("2d")
  try {
    ctx.clearRect(0, 0, 1, 1)
    ctx.fillStyle = trimmed
    ctx.fillRect(0, 0, 1, 1)
    const [r, g, b, a] = ctx.getImageData(0, 0, 1, 1).data
    if (a === 0) return fallback
    const hex = "#" + [r, g, b].map(v => v.toString(16).padStart(2, "0")).join("")
    return hex
  } catch {
    return fallback
  }
}

function themeColors() {
  return {
    base100: normalizeColor(themeVar("--color-base-100"), "#ffffff"),
    base200: normalizeColor(themeVar("--color-base-200"), "#f5f5f5"),
    base300: normalizeColor(themeVar("--color-base-300"), "#e5e5e5"),
    baseContent: normalizeColor(themeVar("--color-base-content"), "#111111"),
    primary: normalizeColor(themeVar("--color-primary"), "#60a5fa"),
    secondary: normalizeColor(themeVar("--color-secondary"), "#818cf8"),
    accent: normalizeColor(themeVar("--color-accent"), "#6366f1"),
    neutral: normalizeColor(themeVar("--color-neutral"), "#64748b"),
    success: normalizeColor(themeVar("--color-success"), "#4ade80"),
    warning: normalizeColor(themeVar("--color-warning"), "#fbbf24"),
    error: normalizeColor(themeVar("--color-error"), "#ef4444")
  }
}

// GraphProjector emits hex colors; remap them to the active theme's semantic tokens.
function remapColor(hex, t) {
  switch ((hex || "").toLowerCase()) {
    case "#60a5fa": return t.primary   // satisfied
    case "#4ade80": return t.success   // actionable
    case "#fbbf24": return t.warning   // blocked
    case "#64748b": return t.neutral   // default node / intra-group edge
    case "#818cf8": return t.secondary // cross-group edge
    case "#6366f1": return t.accent    // special edge
    default: return hex || t.neutral
  }
}

let Hooks = {}

Hooks.SigmaGraph = {
  mounted() {
    // Register server-push handlers once (not in loadAndRender, which also
    // runs on updated()). graph:ready = full (re)render on load;
    // graph:update = targeted merge from a watcher-triggered recompute;
    // graph:error = surface a failure.
    this.handleEvent("graph:ready", ({ data, metrics }) => {
      this.lastMetrics = metrics
      this.updateLoaderText(`Rendering ${data.nodes.length} nodes…`)
      requestAnimationFrame(() => {
        this.clearLoader()
        this.renderGraph(data)
      })
    })
    this.handleEvent("graph:update", ({ data }) => this.applyGraph(data))
    this.handleEvent("graph:error", ({ message }) => this.showError({ message }))
    this.loadAndRender()
  },
  updated() {
    if (this.sigma) { this.sigma.kill(); this.sigma = null }
    this.loadAndRender()
  },
  destroyed() {
    if (this.sigma) { this.sigma.kill(); this.sigma = null }
    this.clearLoader()
    const panel = document.getElementById("graph-debug")
    if (panel) panel.remove()
  },
  loadAndRender() {
    const raw = this.el.dataset.graph
    if (raw) {
      this.renderGraph(JSON.parse(raw))
      return
    }
    this.showLoader("Computing requirements graph…")
  },
  showLoader(message) {
    const t = themeColors()
    this.el.innerHTML = `
      <div style="display:flex;flex-direction:column;align-items:center;justify-content:center;height:100%;gap:12px;color:${t.baseContent}">
        <div style="width:40px;height:40px;border:3px solid ${t.base300};border-top-color:${t.primary};border-radius:50%;animation:sigma-spin 0.8s linear infinite"></div>
        <div data-loader-message style="font-size:1rem;font-weight:600">${message}</div>
        <div data-loader-elapsed style="font-size:0.85rem;opacity:0.7;font-family:ui-monospace,monospace">0.0s</div>
        <div style="font-size:0.75rem;opacity:0.5">Large projects can take a while</div>
      </div>
      <style>@keyframes sigma-spin { to { transform: rotate(360deg) } }</style>
    `
    this.loaderStart = performance.now()
    this.loaderInterval = setInterval(() => {
      const el = this.el.querySelector("[data-loader-elapsed]")
      if (el) {
        const elapsed = ((performance.now() - this.loaderStart) / 1000).toFixed(1)
        el.textContent = `${elapsed}s`
      }
    }, 100)
  },
  updateLoaderText(message) {
    const el = this.el.querySelector("[data-loader-message]")
    if (el) el.textContent = message
  },
  clearLoader() {
    if (this.loaderInterval) {
      clearInterval(this.loaderInterval)
      this.loaderInterval = null
    }
    this.el.innerHTML = ""
  },
  showError(err) {
    this.clearLoader()
    console.error("[SigmaGraph] failed to fetch graph data:", err)
    const t = themeColors()
    this.el.innerHTML = `
      <div style="display:flex;flex-direction:column;align-items:center;justify-content:center;height:100%;gap:8px;color:${t.baseContent};padding:24px;text-align:center">
        <div style="font-weight:600;color:${t.error}">Failed to load graph</div>
        <div style="font-size:0.85rem;opacity:0.7">${err.message || err}</div>
      </div>
    `
  },
  renderGraph(data) {
    const t = themeColors()
    // Full render: tear down any prior instance (the graph:update path reuses
    // the live instance instead — see applyGraph).
    if (this.sigma) { this.sigma.kill(); this.sigma = null }
    const graph = new window.graphology.Graph()
    this.graph = graph

    // Add nodes with theme-remapped colors
    data.nodes.forEach(n => {
      if (!graph.hasNode(n.key)) {
        const attrs = { ...n.attributes, color: remapColor(n.attributes.color, t) }
        graph.addNode(n.key, attrs)
      }
    })

    // Add edges (deduplicate by key). Force edges to base-content so they're
    // visible on dark themes — t.neutral/t.secondary land near-black here.
    const seenEdges = new Set()
    data.edges.forEach(e => {
      if (!seenEdges.has(e.key) && graph.hasNode(e.source) && graph.hasNode(e.target)) {
        seenEdges.add(e.key)
        const attrs = { ...e.attributes, color: t.baseContent }
        graph.addEdgeWithKey(e.key, e.source, e.target, attrs)
      }
    })

    const container = this.el
    const SigmaClass = window.Sigma?.default || window.Sigma
    this.sigma = new SigmaClass(graph, container, {
      renderLabels: true,
      labelColor: { color: t.baseContent },
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

        context.fillStyle = t.base200
        context.strokeStyle = t.primary
        context.lineWidth = 1.5
        context.fillRect(data.x - boxWidth / 2, data.y - size - boxHeight - 4, boxWidth, boxHeight)
        context.strokeRect(data.x - boxWidth / 2, data.y - size - boxHeight - 4, boxWidth, boxHeight)

        context.fillStyle = t.baseContent
        context.textAlign = "center"
        context.textBaseline = "middle"
        context.fillText(label, data.x, data.y - size - boxHeight / 2 - 4)
      },
      defaultEdgeType: "arrow",
      defaultEdgeColor: t.baseContent,
      stagePadding: 80,
      labelRenderedSizeThreshold: 8,
      labelDensity: 0.5,
      labelGridCellSize: 200,
      defaultNodeColor: t.neutral,
      enableEdgeClickEvents: true,
      enableEdgeHoverEvents: true
    })

    if (data.layout === "force") this.runForceLayout(graph)

    const camera = this.sigma.getCamera()
    camera.setState({ ratio: 1.3 })

    // Debug panel — themed
    let debugPanel = document.getElementById("graph-debug")
    if (!debugPanel) {
      debugPanel = document.createElement("details")
      debugPanel.id = "graph-debug"
      debugPanel.className = "bg-base-200 text-base-content border-t border-base-300"
      debugPanel.style.cssText = "position:fixed;bottom:0;left:0;right:0;max-height:40vh;overflow-y:auto;padding:8px 16px;font-family:ui-monospace,monospace;font-size:11px;z-index:9999"
      debugPanel.innerHTML = `<summary style="cursor:pointer;opacity:0.7;margin-bottom:8px">Graph Debug (${data.nodes.length} nodes, ${data.edges.length} edges)</summary><div id="graph-debug-metrics" style="margin-bottom:8px"></div><pre id="graph-debug-content" style="margin:0"></pre>`
      document.body.appendChild(debugPanel)
    }
    const metricsEl = document.getElementById("graph-debug-metrics")
    if (metricsEl && this.lastMetrics) {
      const m = this.lastMetrics
      const total = Object.entries(m)
        .filter(([k]) => k.endsWith("_ms"))
        .reduce((a, [, v]) => a + v, 0)
      const rows = Object.entries(m)
        .map(([k, v]) => `  ${k.padEnd(22)} ${v}${k.endsWith("_ms") ? "ms" : ""}`)
        .join("\n")
      metricsEl.innerHTML = `<pre style="margin:0;color:inherit">METRICS (total ${total}ms):\n${rows}</pre>`
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

      const panel = document.getElementById("graph-debug")
      if (!panel) return
      panel.open = true
      const inHtml = inEdges.map(e => `  ← ${e.from}`).join("\n")
      const outHtml = outEdges.map(e => `  → ${e.to}`).join("\n")
      const content = document.getElementById("graph-debug-content")
      content.innerHTML = `<strong>${node}</strong>  (${attrs.label || ""})
<span style="color:${t.primary}">IN (${inEdges.length}):</span>
${inHtml || "  (none)"}
<span style="color:${t.success}">OUT (${outEdges.length}):</span>
${outHtml || "  (none)"}`
    })

    this.sigma.on("clickEdge", ({ edge }) => {
      const source = graph.source(edge)
      const target = graph.target(edge)
      const sourceLabel = graph.getNodeAttributes(source).label || source
      const targetLabel = graph.getNodeAttributes(target).label || target

      const panel = document.getElementById("graph-debug")
      if (!panel) return
      panel.open = true
      const content = document.getElementById("graph-debug-content")
      content.textContent = `EDGE: ${edge}\n\n  FROM: ${source}\n        (${sourceLabel})\n\n  TO:   ${target}\n        (${targetLabel})`
    })

    this.sigma.on("enterNode", () => { container.style.cursor = "pointer" })
    this.sigma.on("leaveNode", () => { container.style.cursor = "default" })
    this.sigma.on("enterEdge", () => { container.style.cursor = "pointer" })
    this.sigma.on("leaveEdge", () => { container.style.cursor = "default" })
  },
  // Targeted merge from a watcher-triggered recompute. Mutates the live
  // graphology graph in place so existing node positions survive — only
  // changed attributes (status/color) update, new nodes are slotted in near
  // their neighbors, and removed nodes/edges drop. No global relayout.
  applyGraph(data) {
    if (!this.graph || !this.sigma) return this.renderGraph(data)
    const t = themeColors()
    const g = this.graph

    const nextNodes = new Set(data.nodes.map(n => n.key))
    const nextEdges = new Set(data.edges.map(e => e.key))

    // Drop what's gone (snapshot keys first; dropNode also drops its edges).
    g.edges().forEach(key => { if (!nextEdges.has(key) && g.hasEdge(key)) g.dropEdge(key) })
    g.nodes().forEach(key => { if (!nextNodes.has(key)) g.dropNode(key) })

    // Upsert nodes: existing -> merge attrs but NOT x/y (keep layout); new ->
    // place near already-positioned neighbors.
    data.nodes.forEach(n => {
      const { x, y, ...rest } = n.attributes
      const attrs = { ...rest, color: remapColor(n.attributes.color, t) }
      if (g.hasNode(n.key)) {
        g.mergeNodeAttributes(n.key, attrs)
      } else {
        g.addNode(n.key, { ...attrs, ...this.placeNewNode(g, n.key, data.edges) })
      }
    })

    // Add new edges once both endpoints exist.
    const seen = new Set()
    data.edges.forEach(e => {
      if (seen.has(e.key)) return
      seen.add(e.key)
      if (!g.hasEdge(e.key) && g.hasNode(e.source) && g.hasNode(e.target)) {
        g.addEdgeWithKey(e.key, e.source, e.target, { ...e.attributes, color: t.baseContent })
      }
    })

    this.sigma.refresh()
  },
  placeNewNode(g, key, edges) {
    const placed = []
    edges.forEach(e => {
      if (e.source === key && g.hasNode(e.target)) placed.push(e.target)
      if (e.target === key && g.hasNode(e.source)) placed.push(e.source)
    })
    if (placed.length === 0) return { x: (Math.random() - 0.5) * 10, y: (Math.random() - 0.5) * 10 }
    let x = 0, y = 0
    placed.forEach(n => { const a = g.getNodeAttributes(n); x += a.x || 0; y += a.y || 0 })
    return { x: x / placed.length + (Math.random() - 0.5) * 2, y: y / placed.length + (Math.random() - 0.5) * 2 }
  },
  runForceLayout(graph) {
    const iterations = 300
    const repulsion = 50000
    const attraction = 0.005
    const damping = 0.85

    const nodes = graph.nodes()
    const vel = {}
    nodes.forEach(n => { vel[n] = { vx: 0, vy: 0 } })

    for (let i = 0; i < iterations; i++) {
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
  hooks: {...colocatedHooks, ...Hooks}
})

liveSocket.connect()
window.liveSocket = liveSocket

// Server-pushed file downloads (e.g. the stories Export button).
window.addEventListener("phx:download_file", (ev) => {
  const {content, filename, content_type} = ev.detail
  const blob = new Blob([content], {type: content_type || "text/plain"})
  const url = URL.createObjectURL(blob)
  const a = document.createElement("a")
  a.href = url
  a.download = filename || "download.txt"
  document.body.appendChild(a)
  a.click()
  document.body.removeChild(a)
  URL.revokeObjectURL(url)
})

// --- Local app: delegated copy-button handler ---
// Any element with `.copy-btn[data-copy]` becomes a clipboard button.
// Used by the InitLive step pages so users can one-click the prompt
// into their clipboard for pasting into Claude Code.
document.addEventListener("click", (ev) => {
  const btn = ev.target.closest(".copy-btn[data-copy]")
  if (!btn) return
  const text = btn.getAttribute("data-copy")
  const original = btn.textContent
  const restore = () => { btn.textContent = original }
  const done = () => { btn.textContent = "✓ Copied"; setTimeout(restore, 1800) }
  if (navigator.clipboard && navigator.clipboard.writeText) {
    navigator.clipboard.writeText(text).then(done, () => copyFallback(text, done))
  } else {
    copyFallback(text, done)
  }
})

function copyFallback(text, done) {
  const ta = document.createElement("textarea")
  ta.value = text
  document.body.appendChild(ta)
  ta.select()
  try { document.execCommand("copy") } catch (_) {}
  document.body.removeChild(ta)
  done()
}
