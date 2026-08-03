// Mounts Stripe's Payment Element and confirms the subscription's first
// payment in place. The tier is not granted here — the webhook does that; this
// only tells the LiveView how it went so the page can say something honest.
//
// Stripe.js is fetched on demand rather than from a tag in the root layout. It
// has to come from js.stripe.com (PCI), so it cannot be bundled, and a blocking
// script in the layout would load it on every marketing pageview for a form
// only buyers ever see.
let stripeJsPromise = null

function loadStripeJs() {
  if (window.Stripe) return Promise.resolve(window.Stripe)
  if (stripeJsPromise) return stripeJsPromise

  stripeJsPromise = new Promise((resolve, reject) => {
    const script = document.createElement("script")
    script.src = "https://js.stripe.com/v3"
    script.async = true
    script.onload = () => resolve(window.Stripe)
    script.onerror = () => {
      // Clear it so a later mount can retry rather than caching the failure.
      stripeJsPromise = null
      reject(new Error("Stripe.js failed to load"))
    }
    document.head.appendChild(script)
  })

  return stripeJsPromise
}

export const StripePaymentElement = {
  async mounted() {
    const pk = this.el.dataset.publishableKey
    const clientSecret = this.el.dataset.clientSecret

    if (!pk || !clientSecret) return this.showError("Payment form failed to load.")

    let Stripe
    try {
      Stripe = await loadStripeJs()
    } catch (_e) {
      return this.showError("Payment form failed to load.")
    }

    // The hook can be torn down while the script is still in flight.
    if (!this.el.isConnected) return

    this.stripe = Stripe(pk)
    this.elements = this.stripe.elements({clientSecret})
    this.elements.create("payment").mount(this.el.querySelector("#payment-element"))

    this.el.querySelector("#payment-form").addEventListener("submit", (e) => this.submit(e))
  },

  async submit(e) {
    e.preventDefault()
    const btn = this.el.querySelector("#payment-submit")
    btn.disabled = true
    this.showError("")

    const {error} = await this.stripe.confirmPayment({
      elements: this.elements,
      // Cards confirm in place; only redirect-based methods leave the page.
      redirect: "if_required",
    })

    if (error) {
      btn.disabled = false
      this.showError(error.message || "Payment could not be completed.")
      this.pushEvent("payment_failed", {message: error.message || "Payment could not be completed."})
      return
    }

    this.pushEvent("payment_confirmed", {})
  },

  showError(message) {
    const el = this.el.querySelector("#payment-error")
    if (el) el.textContent = message
  },
}
