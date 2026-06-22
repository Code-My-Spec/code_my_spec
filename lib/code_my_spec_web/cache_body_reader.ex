defmodule CodeMySpecWeb.CacheBodyReader do
  @moduledoc """
  Plug.Parsers body reader that stashes the raw request body for webhook
  routes so signature verification can hash the exact bytes Resend signed.

  Only caches under `/webhooks/` to avoid holding large bodies (uploads, etc.)
  in memory for every request.
  """

  @cache_prefixes ["/webhooks/"]

  def read_body(conn, opts) do
    {:ok, body, conn} = Plug.Conn.read_body(conn, opts)

    if cache?(conn.request_path) do
      {:ok, body, update_in(conn.assigns[:raw_body], &[body | &1 || []])}
    else
      {:ok, body, conn}
    end
  end

  defp cache?(path), do: Enum.any?(@cache_prefixes, &String.starts_with?(path, &1))
end
