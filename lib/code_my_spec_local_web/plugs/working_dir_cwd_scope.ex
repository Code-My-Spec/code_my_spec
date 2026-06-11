defmodule CodeMySpecLocalWeb.Plugs.WorkingDirCwdScope do
  @moduledoc """
  Assigns a minimal cwd-only scope (no project) from the resolved working dir.

  Unlike `WorkingDirScope`, this never looks up or requires a linked project,
  so bootstrap flows like `/codemyspec:init` can run before any project
  exists. Expects `conn.assigns.working_dir` (set by the `WorkingDir` plug).
  """

  import Plug.Conn

  alias CodeMySpec.Users.Scope

  @behaviour Plug

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    case Scope.for_local_cwd(conn.assigns[:working_dir]) do
      {:ok, scope} ->
        assign(conn, :current_scope, scope)

      {:error, _reason} ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(400, Jason.encode!(%{error: "X-Working-Dir header required"}))
        |> halt()
    end
  end
end
