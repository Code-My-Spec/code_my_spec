defmodule CodeMySpecWeb.Plugs.CSPReportOnly do
  @moduledoc """
  Adds a `Content-Security-Policy-Report-Only` header in monitor mode.

  Report-only blocks NOTHING: it only makes the browser report what *would* be
  blocked (to the devtools console, and to `report-uri` if configured). This lets
  us validate the policy against real traffic before enforcing it.

  A fresh nonce is generated per request and assigned as `:csp_nonce` so the inline
  `<script>` tags in the root layout can carry `nonce={assigns[:csp_nonce]}`. Once
  the violation reports are clean, promote this to enforcement by renaming the
  header to `content-security-policy` (and fold the `base-uri`/`frame-ancestors`
  directives currently set via `put_secure_browser_headers` into it).
  """
  import Plug.Conn

  @spec init(keyword()) :: keyword()
  def init(opts), do: opts

  @spec call(Plug.Conn.t(), keyword()) :: Plug.Conn.t()
  def call(conn, _opts) do
    nonce = 18 |> :crypto.strong_rand_bytes() |> Base.encode64()

    conn
    |> assign(:csp_nonce, nonce)
    |> put_resp_header("content-security-policy-report-only", policy(nonce))
  end

  defp policy(nonce) do
    [
      "default-src 'self'",
      "script-src 'self' 'nonce-#{nonce}' https://www.googletagmanager.com",
      "connect-src 'self' https://www.googletagmanager.com https://www.google-analytics.com https://region1.google-analytics.com",
      "img-src 'self' data: https://images.codemyspec.com https://www.google-analytics.com https://www.googletagmanager.com",
      "style-src 'self' 'unsafe-inline'",
      "font-src 'self'",
      "object-src 'none'",
      "base-uri 'self'",
      "frame-ancestors 'self'"
    ]
    |> Enum.join("; ")
  end
end
