defmodule CodeMySpecWeb.Plugs.CSP do
  @moduledoc """
  Sets an ENFORCING `Content-Security-Policy` header (validated in report-only
  first, flipped to enforce 2026-06-03 after a clean cross-site validation).

  A fresh nonce is generated per request and assigned as `:csp_nonce` so the inline
  `<script>` tags in the root layout carry `nonce={assigns[:csp_nonce]}`. This plug
  runs last in the `:browser` pipeline, so `put_resp_header/3` replaces Phoenix's
  default `base-uri`/`frame-ancestors` CSP with this fuller policy (which already
  includes both directives).

  To revert to monitor mode, change the header name back to
  `content-security-policy-report-only`.
  """
  import Plug.Conn

  alias CodeMySpec.Projects
  alias CodeMySpec.Workspaces.PreviewAddress

  @spec init(keyword()) :: keyword()
  def init(opts), do: opts

  @spec call(Plug.Conn.t(), keyword()) :: Plug.Conn.t()
  def call(conn, _opts) do
    nonce = 18 |> :crypto.strong_rand_bytes() |> Base.encode64()

    conn
    |> assign(:csp_nonce, nonce)
    |> put_resp_header("content-security-policy", policy(nonce, project(conn)))
  end

  # Route matching sets path params before the pipeline (this plug included)
  # runs, so a project-scoped route's `:project_id` is already here — no
  # separate lookup plug needed just to answer "which project is this policy
  # for". Routes with no project in the path (marketing pages, the guided
  # intake's own preview) get `nil` and fall back to
  # `PreviewAddress.extra_frame_origins/1`'s config/built-in default.
  #
  # `get_project_by_id/1` is the one built for exactly this — a web-side
  # lookup with no scope, safe against a malformed or unknown id.
  defp project(%{path_params: %{"project_id" => id}}) when is_binary(id),
    do: Projects.get_project_by_id(id)

  defp project(_conn), do: nil

  defp policy(nonce, project) do
    [
      "default-src 'self'",
      # js.stripe.com must be loadable and framed: the Payment Element is
      # Stripe's own iframe, which is what keeps card details off our origin.
      # Without these the form silently never mounts — the page renders, the
      # element does not, and nothing in the server logs says why.
      # Clarity's tag loads its script from scripts.clarity.ms, not www.
      "script-src 'self' 'nonce-#{nonce}' https://www.googletagmanager.com https://static.cloudflareinsights.com https://js.stripe.com https://*.clarity.ms",
      # Previews are framed from a subdomain of our own domain, which is not
      # `'self'` — a different host is a different origin however closely
      # related. Without this the app is willing to be framed and we refuse to
      # frame it, which looks identical to the app refusing: a blank pane, no
      # server-side error, and an iframe element that inspects perfectly.
      #
      # The extra origins are for the previewed app's own OAuth flows —
      # "Sign in with Google/GitHub" sends the frame to the provider's own
      # domain, which is neither `'self'` nor the preview's origin. Per
      # project (see `PreviewAddress.csp_extra_frame_origins/1`) — `project`
      # is `nil` off a route with no `:project_id`, which falls back to the
      # config/built-in default there.
      "frame-src 'self' #{PreviewAddress.csp_origin()} #{Enum.join(PreviewAddress.csp_extra_frame_origins(project), " ")} https://js.stripe.com https://hooks.stripe.com",
      # Clarity's data collection rotates across regional subdomains
      # (https://*.clarity.ms), not just www — a single hostname here silently
      # drops session data with no visible error, the exact failure mode this
      # policy exists to avoid for every other analytics vendor listed.
      #
      # GA4 sends hits to *.google-analytics.com and *.analytics.google.com,
      # and with Google Signals on, to www.google.com as well (Google's CSP
      # guide for GA4). Blocked hits fail silently: the page view never counts.
      "connect-src 'self' https://*.googletagmanager.com https://*.google-analytics.com https://*.analytics.google.com https://www.google.com https://cloudflareinsights.com https://api.stripe.com https://*.clarity.ms",
      # Google Signals' audience pixel loads from the visitor's country domain
      # (www.google.ca seen 2026-10-30); a CSP host cannot wildcard a TLD, so
      # the countries we serve are listed.
      "img-src 'self' data: https://images.codemyspec.com https://*.google-analytics.com https://*.googletagmanager.com https://www.google.com https://www.google.ca https://img.shields.io",
      # Video is served from the same bucket as the images, but media-src does
      # not inherit from img-src — without this it falls back to default-src
      # 'self' and every <video> from the CDN is blocked. The poster still
      # loads, because that is an image, so the failure looks like a video
      # that simply never plays.
      "media-src 'self' https://images.codemyspec.com",
      "style-src 'self' 'unsafe-inline'",
      # data: is for Clarity, which injects data-URI fonts as part of its
      # recording instrumentation (microsoft/clarity#688) — without it,
      # Clarity's script still loads but throws CSP errors afterward.
      "font-src 'self' data:",
      "object-src 'none'",
      "base-uri 'self'",
      "frame-ancestors 'self'"
    ]
    |> Enum.join("; ")
  end
end
