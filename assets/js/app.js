// If you want to use Phoenix channels, run `mix help phx.gen.channel`
// to get started and then uncomment the line below.
// import "./user_socket.js"

// You can include dependencies in two ways.
//
// The simplest option is to put them in assets/vendor and
// import them using relative paths:
//
//     import "../vendor/some-package.js"
//
// Alternatively, you can `npm install some-package --prefix assets` and import
// them using a path starting with the package name:
//
//     import "some-package"
//
// If you have dependencies that try to import CSS, esbuild will generate a separate `app.css` file.
// To load it, simply add a second `<link>` to your `root.html.heex` file.

// Include phoenix_html to handle method=PUT/DELETE in forms and buttons.
import "phoenix_html"
// Establish Phoenix Socket and LiveView configuration.
import { Socket } from "phoenix"
import { LiveSocket } from "phoenix_live_view"
import { hooks as colocatedHooks } from "phoenix-colocated/code_my_spec"
import { StripePaymentElement } from "./stripe_payment"
import { SigmaGraph } from "./sigma_graph"
import topbar from "../vendor/topbar"
import Sortable from "../vendor/Sortable.min.js"

// Make Sortable available globally for colocated hooks
window.Sortable = Sortable

let Hooks = {
  StripePaymentElement,
  SigmaGraph,
  Copy: {
    mounted() {
      let { to } = this.el.dataset;
      this.el.addEventListener("click", (ev) => {
        ev.preventDefault();
        let text = document.querySelector(to).value;
        navigator.clipboard.writeText(text);
      });
    },
  },
}

const csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content")
const liveSocket = new LiveSocket("/live", Socket, {
  longPollFallbackMs: 2500,
  params: { _csrf_token: csrfToken },
  hooks: { ...colocatedHooks, ...Hooks },
})

// Show progress bar on live navigation and form submits
topbar.config({ barColors: { 0: "#29d" }, shadowColor: "rgba(0, 0, 0, .3)" })
window.addEventListener("phx:page-loading-start", _info => topbar.show(300))
window.addEventListener("phx:page-loading-stop", _info => topbar.hide())

// connect if there are any LiveViews on the page
liveSocket.connect()

// --- Marketing chrome: delegated copy-button handler ---
// Any element with `.copy-btn[data-copy]` becomes a clipboard button.
// Used by /codemyspec and /marketmyspec install cards across the marketing
// pages. Delegation on document handles initial render, LiveView patches,
// and pages added later — no per-page rebinding needed.
//
// GA4 (hybrid): if the button has `data-event-name`, fire that event via
// gtag('event', ...) directly. Any other `data-event-*` attributes become
// event params (kebab → snake). gtag handles sessions, engagement, and
// attribution natively — no server round-trip needed for behavior events.
// Example: `data-event-name="install_command_copy" data-event-location="homepage_hero"`
document.addEventListener("click", (ev) => {
  const btn = ev.target.closest(".copy-btn[data-copy]");
  if (!btn) return;
  const text = btn.getAttribute("data-copy");
  const original = btn.textContent;
  const restore = () => { btn.textContent = original; };
  const done = () => {
    btn.textContent = "[ ✓ COPIED ]";
    setTimeout(restore, 1800);
    fireCopyEvent(btn);
  };
  if (navigator.clipboard && navigator.clipboard.writeText) {
    navigator.clipboard.writeText(text).then(done, () => fallback(text, done));
  } else {
    fallback(text, done);
  }
});

function fireCopyEvent(btn) {
  const name = btn.getAttribute("data-event-name");
  if (!name || typeof gtag !== "function") return;
  const params = {};
  for (const attr of btn.attributes) {
    if (attr.name.startsWith("data-event-") && attr.name !== "data-event-name") {
      params[attr.name.replace("data-event-", "").replace(/-/g, "_")] = attr.value;
    }
  }
  gtag('event', name, params);
}

function fallback(text, done) {
  const ta = document.createElement("textarea");
  ta.value = text;
  document.body.appendChild(ta);
  ta.select();
  try { document.execCommand("copy"); } catch (_) {}
  document.body.removeChild(ta);
  done();
}

// --- Marketing chrome: delegated CTA click handler ---
// Tracks outbound clicks on conversion CTAs across blog posts, landers,
// and the homepage. Catches two cases:
//   1. Explicit — any <a data-event-label="...">. Use this when the CTA
//      surface is rendered from a heex component or inline-HTML block
//      and you want a stable label (e.g. cta-signature-register).
//   2. Implicit — any <a href> pointing at /users/register* or
//      /products/code-my-spec*. Catches markdown-authored anchors
//      (`[text](/products/code-my-spec?...)`) without requiring
//      content edits. Markdown posts get tracked for free.
//
// GA4 (hybrid): fires cta_click via gtag('event', ...) directly.
document.addEventListener("click", (ev) => {
  const a = ev.target.closest("a[href]");
  if (!a) return;
  const href = a.getAttribute("href") || "";
  const explicitLabel = a.getAttribute("data-event-label");
  if (!explicitLabel && !isImplicitCTA(href)) return;

  const url = parseHref(href);
  if (!url) return;

  if (typeof gtag !== "function") return;

  const params = {
    event_label: explicitLabel || deriveLabel(url),
    target_path: url.pathname,
    source_path: window.location.pathname
  };
  const campaign = url.searchParams.get("utm_campaign");
  if (campaign) params.utm_campaign = campaign;

  gtag('event', 'cta_click', params);
});

function isImplicitCTA(href) {
  return /^\/users\/register(\?|$|\/)/.test(href) ||
         /^\/products\/code-my-spec(\?|$|\/)/.test(href);
}

function parseHref(href) {
  try { return new URL(href, window.location.origin); }
  catch (_) { return null; }
}

function deriveLabel(url) {
  if (url.pathname.startsWith("/users/register")) return "cta-register-implicit";
  if (url.pathname.startsWith("/products/code-my-spec")) return "cta-lander-implicit";
  return "cta-other";
}

// expose liveSocket on window for web console debug logs and latency simulation:
// >> liveSocket.enableDebug()
// >> liveSocket.enableLatencySim(1000)  // enabled for duration of browser session
// >> liveSocket.disableLatencySim()
window.liveSocket = liveSocket

// --- Web Push Notifications ---

let pushBusy = false

function getNotifBtn() {
  return document.getElementById("enable-notifications-btn")
}

// Update bell icon to reflect current subscription state
async function updateNotificationButton() {
  const btn = getNotifBtn()
  if (!btn) return
  if (!("serviceWorker" in navigator) || !("PushManager" in window)) {
    btn.style.display = "none"
    return
  }

  const reg = await navigator.serviceWorker.ready
  const sub = await reg.pushManager.getSubscription()
  const iconOff = btn.querySelector("[data-notif-icon-off]")
  const iconOn = btn.querySelector("[data-notif-icon-on]")

  btn.disabled = false
  const spinner = btn.querySelector("#notif-spinner")
  if (spinner) spinner.remove()

  if (sub) {
    btn.dataset.subscribed = "true"
    btn.dataset.tip = "Disable notifications"
    if (iconOff) iconOff.classList.add("hidden")
    if (iconOn) iconOn.classList.remove("hidden")
  } else {
    btn.dataset.subscribed = "false"
    btn.dataset.tip = "Enable notifications"
    if (iconOff) iconOff.classList.remove("hidden")
    if (iconOn) iconOn.classList.add("hidden")
  }
}

function setButtonLoading() {
  const btn = getNotifBtn()
  if (!btn) return
  btn.disabled = true
  const iconOff = btn.querySelector("[data-notif-icon-off]")
  const iconOn = btn.querySelector("[data-notif-icon-on]")
  if (iconOff) iconOff.classList.add("hidden")
  if (iconOn) iconOn.classList.add("hidden")
  const spinner = document.createElement("span")
  spinner.id = "notif-spinner"
  spinner.className = "loading loading-spinner loading-sm text-base-content"
  btn.appendChild(spinner)
}

// Register service worker
if ("serviceWorker" in navigator) {
  navigator.serviceWorker.register("/sw.js").then(function (reg) {
    console.log("[Push] Service worker registered", reg.scope)
    updateNotificationButton()
    resyncPushSubscription()
  }).catch(function (err) {
    console.warn("[Push] Service worker registration failed", err)
  })
}

// The server deletes subscription rows when a push bounces (404/410), but the
// browser-side subscription survives — so the bell shows "on" while the server
// has nothing to send to. Re-upsert the subscription on every load (idempotent
// on endpoint) so the server record always matches the browser's reality.
async function resyncPushSubscription() {
  try {
    const reg = await navigator.serviceWorker.ready
    const sub = await reg.pushManager.getSubscription()
    if (!sub) return
    await fetch("/api/browser/push-subscriptions", {
      method: "POST",
      headers: {
        "content-type": "application/json",
        "x-csrf-token": csrfToken
      },
      body: JSON.stringify({ subscription: sub.toJSON() })
    })
  } catch (err) {
    console.warn("[Push] Subscription resync failed", err)
  }
}

// Hydrate button state on LiveView navigations
window.addEventListener("phx:page-loading-stop", function () {
  updateNotificationButton()
})

// Listen for notification toggle from LiveView
window.addEventListener("phx:toggle-push-notifications", async function () {
  if (pushBusy) return
  pushBusy = true
  setButtonLoading()

  try {
    const reg = await navigator.serviceWorker.ready
    const existingSub = await reg.pushManager.getSubscription()

    // If already subscribed, unsubscribe
    if (existingSub) {
      await fetch("/api/browser/push-subscriptions", {
        method: "DELETE",
        headers: {
          "content-type": "application/json",
          "x-csrf-token": csrfToken
        },
        body: JSON.stringify({ endpoint: existingSub.endpoint })
      })
      await existingSub.unsubscribe()
      console.log("[Push] Unsubscribed")
      updateNotificationButton()
      return
    }

    // Otherwise, subscribe
    const permission = await Notification.requestPermission()
    if (permission !== "granted") {
      console.log("[Push] Permission denied")
      updateNotificationButton()
      return
    }

    // Fetch VAPID public key from server
    const vapidResp = await fetch("/api/browser/push-subscriptions/vapid-key")
    if (!vapidResp.ok) {
      const text = await vapidResp.text()
      console.error("[Push] Failed to fetch VAPID key:", vapidResp.status, text)
      updateNotificationButton()
      return
    }
    const { vapid_public_key } = await vapidResp.json()

    // Convert VAPID key from base64url to Uint8Array
    const applicationServerKey = urlBase64ToUint8Array(vapid_public_key)

    // Subscribe via PushManager
    const subscription = await reg.pushManager.subscribe({
      userVisibleOnly: true,
      applicationServerKey: applicationServerKey
    })

    // Send subscription to server
    const resp = await fetch("/api/browser/push-subscriptions", {
      method: "POST",
      headers: {
        "content-type": "application/json",
        "x-csrf-token": csrfToken
      },
      body: JSON.stringify({ subscription: subscription.toJSON() })
    })

    if (resp.ok) {
      console.log("[Push] Subscribed successfully")
    } else {
      console.error("[Push] Subscription save failed:", resp.status, await resp.text())
    }

    updateNotificationButton()
  } catch (err) {
    console.error("[Push] Error:", err)
    updateNotificationButton()
  } finally {
    pushBusy = false
  }
})

function urlBase64ToUint8Array(base64String) {
  const padding = "=".repeat((4 - (base64String.length % 4)) % 4)
  const base64 = (base64String + padding).replace(/-/g, "+").replace(/_/g, "/")
  const rawData = window.atob(base64)
  const outputArray = new Uint8Array(rawData.length)
  for (let i = 0; i < rawData.length; ++i) {
    outputArray[i] = rawData.charCodeAt(i)
  }
  return outputArray
}

// The lines below enable quality of life phoenix_live_reload
// development features:
//
//     1. stream server logs to the browser console
//     2. click on elements to jump to their definitions in your code editor
//
if (process.env.NODE_ENV === "development") {
  window.addEventListener("phx:live_reload:attached", ({ detail: reloader }) => {
    // Enable server log streaming to client.
    // Disable with reloader.disableServerLogs()
    reloader.enableServerLogs()

    // Open configured PLUG_EDITOR at file:line of the clicked element's HEEx component
    //
    //   * click with "c" key pressed to open at caller location
    //   * click with "d" key pressed to open at function component definition location
    let keyDown
    window.addEventListener("keydown", e => keyDown = e.key)
    window.addEventListener("keyup", e => keyDown = null)
    window.addEventListener("click", e => {
      if (keyDown === "c") {
        e.preventDefault()
        e.stopImmediatePropagation()
        reloader.openEditorAtCaller(e.target)
      } else if (keyDown === "d") {
        e.preventDefault()
        e.stopImmediatePropagation()
        reloader.openEditorAtDef(e.target)
      }
    }, true)

    window.liveReloader = reloader
  })
}

