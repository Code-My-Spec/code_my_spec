defmodule CodeMySpec.PublicUrl do
  @moduledoc """
  Public-facing URL of the application.

  Lives in `lib/code_my_spec/` so domain code (email links, OAuth
  callbacks, IndexNow notifications) can reference the public URL
  without depending on the `CodeMySpecWeb` boundary.

  Single source of truth: the endpoint's `:url` config under
  `:code_my_spec, CodeMySpecWeb.Endpoint`. The atom is used here as
  a config key, not as a module reference, so it doesn't pull the
  Web boundary into this module's dependency graph. Whatever
  `dev.exs` / `runtime.exs` / the cloudflare tunnel flow set as the
  endpoint host is what `PublicUrl.base/0` returns — no second
  variable to keep in sync.
  """

  @doc """
  Returns the public base URL, e.g. `"https://codemyspec.com"`.

  Builds `<scheme>://<host>[:<port>]` from the endpoint's `:url`
  config, omitting the port when it's the scheme default (443 for
  https, 80/nil for http).
  """
  @spec base() :: String.t()
  def base, do: build(CodeMySpecWeb.Endpoint)

  @doc """
  Returns the local CLI server's base URL, e.g. `"http://127.0.0.1:4003"`.

  Reads from the local endpoint's `:url` / `:http` config under
  `:code_my_spec, CodeMySpecLocalWeb.Endpoint`. Used by MCP-tool
  responses that point the agent at the local sign-in screen.
  """
  @spec local_base() :: String.t()
  def local_base, do: build(CodeMySpecLocalWeb.Endpoint)

  defp build(endpoint_key) do
    cfg = Application.get_env(:code_my_spec, endpoint_key, [])
    url_cfg = Keyword.get(cfg, :url, [])

    scheme = Keyword.get(url_cfg, :scheme, "http")
    host = Keyword.get(url_cfg, :host, "localhost")
    port = Keyword.get(url_cfg, :port) || http_port(cfg)

    cond do
      scheme == "https" and port in [nil, 443] -> "https://#{host}"
      scheme == "http" and port in [nil, 80] -> "http://#{host}"
      true -> "#{scheme}://#{host}:#{port}"
    end
  end

  defp http_port(cfg) do
    case Keyword.get(cfg, :http) do
      http when is_list(http) -> Keyword.get(http, :port)
      _ -> nil
    end
  end
end
