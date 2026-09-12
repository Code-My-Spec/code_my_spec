defmodule CodeMySpecLocalWeb.Plugs.LocalScope do
  @moduledoc """
  Loads the project scope from the working directory's config file.
  """

  import Plug.Conn
  require Logger

  alias CodeMySpec.Projects

  @behaviour Plug

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    working_dir = conn.assigns[:working_dir]

    case Projects.scope_from_local_config(working_dir) do
      {:ok, scope} ->
        assign(conn, :current_scope, scope)

      {:error, reason} ->
        Logger.warning("[LocalScope] Failed to load scope: #{inspect(reason)}")

        conn
        |> put_resp_content_type("application/json")
        |> send_resp(400, Jason.encode!(%{error: "No project found: #{reason}"}))
        |> halt()
    end
  end
end
