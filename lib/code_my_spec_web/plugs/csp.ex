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

  @spec init(keyword()) :: keyword()
  def init(opts), do: opts

  @spec call(Plug.Conn.t(), keyword()) :: Plug.Conn.t()
  def call(conn, _opts) do
    nonce = 18 |> :crypto.strong_rand_bytes() |> Base.encode64()

    conn
    |> assign(:csp_nonce, nonce)
    |> put_resp_header("content-security-policy", policy(nonce))
  end

  defp policy(nonce) do
    [
      "default-src 'self'",
      "script-src 'self' 'nonce-#{nonce}' https://www.googletagmanager.com https://static.cloudflareinsights.com",
      "connect-src 'self' https://www.googletagmanager.com https://www.google-analytics.com https://region1.google-analytics.com https://cloudflareinsights.com",
      "img-src 'self' data: https://images.codemyspec.com https://www.google-analytics.com https://www.googletagmanager.com https://img.shields.io",
      "style-src 'self' 'unsafe-inline'",
      "font-src 'self'",
      "object-src 'none'",
      "base-uri 'self'",
      "frame-ancestors 'self'"
    ]
    |> Enum.join("; ")
  end
end
