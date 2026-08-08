// Local web LiveView setup (port 4003, localhost only)
import {Socket} from "phoenix"
import {LiveSocket} from "phoenix_live_view"
import {hooks as colocatedHooks} from "phoenix-colocated/code_my_spec"
import Sortable from "../vendor/Sortable.min.js"
import {SigmaGraph} from "./sigma_graph"

// Colocated hooks defined in local LiveViews (`:type={Phoenix.LiveView.ColocatedHook}`)
// were never registered here, so every one of them — including the story
// scheduler's drag-and-drop — was dead on the local app. Sortable is exposed
// globally because those hooks reach for `window.Sortable`.
window.Sortable = Sortable
// graphology + sigma loaded via script tags in root layout (UMD globals)

let Hooks = {SigmaGraph}

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
