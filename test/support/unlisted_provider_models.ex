defmodule CodeMySpecTest.UnlistedProviderModels do
  @moduledoc """
  The suite's default for `Agents.ProviderModels`: every provider answers 404,
  so a model list is `:unknown` (allowed) unless a test installs a cassette.
  """
  @behaviour Plug

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts), do: Plug.Conn.send_resp(conn, 404, "")
end
