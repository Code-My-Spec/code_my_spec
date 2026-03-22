// Local web LiveView setup (port 4003, localhost only)
import {Socket} from "phoenix"
import {LiveSocket} from "phoenix_live_view"

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

let csrfToken = document.querySelector("meta[name='csrf-token']")?.getAttribute("content")
let liveSocket = new LiveSocket("/local-live", Socket, {
  params: {_csrf_token: csrfToken},
  hooks: Hooks
})

liveSocket.connect()
window.liveSocket = liveSocket
