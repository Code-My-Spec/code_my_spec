// Local web LiveView setup (port 4002, localhost only)
import {Socket} from "phoenix"
import {LiveSocket} from "phoenix_live_view"

let csrfToken = document.querySelector("meta[name='csrf-token']")?.getAttribute("content")
let liveSocket = new LiveSocket("/local-live", Socket, {
  params: {_csrf_token: csrfToken}
})

liveSocket.connect()
window.liveSocket = liveSocket
