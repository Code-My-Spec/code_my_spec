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
  def base do
    cfg =
      :code_my_spec
      |> Application.get_env(CodeMySpecWeb.Endpoint, [])
      |> Keyword.get(:url, [])

    scheme = Keyword.get(cfg, :scheme, "http")
    host = Keyword.get(cfg, :host, "localhost")
    port = Keyword.get(cfg, :port)

    cond do
      scheme == "https" and port in [nil, 443] -> "https://#{host}"
      scheme == "http" and port in [nil, 80] -> "http://#{host}"
      true -> "#{scheme}://#{host}:#{port}"
    end
  end
end
