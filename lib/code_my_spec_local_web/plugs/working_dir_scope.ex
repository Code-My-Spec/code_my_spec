defmodule CodeMySpecLocalWeb.Plugs.WorkingDirScope do
  @moduledoc """
  Loads project scope from the working directory by matching `local_path`.

  Looks up the project in the DB by its `local_path` field, then builds
  a scope via `Scope.for_local_project/1`. No config.yml needed.
  """

  import Plug.Conn

  alias CodeMySpec.Projects
  alias CodeMySpec.Users.Scope

  @behaviour Plug

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    working_dir = conn.assigns[:working_dir]

    with {:ok, project} <- Projects.get_project_by_local_path(working_dir),
         {:ok, scope} <- Scope.for_local_project(project) do
      assign(conn, :current_scope, scope)
    else
      {:error, :not_found} ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(404, Jason.encode!(%{error: "No project found for path: #{working_dir}"}))
        |> halt()

      {:error, reason} ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(400, Jason.encode!(%{error: "Failed to load project: #{inspect(reason)}"}))
        |> halt()
    end
  end
end
