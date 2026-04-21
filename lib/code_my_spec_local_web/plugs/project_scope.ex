defmodule CodeMySpecLocalWeb.Plugs.ProjectScope do
  @moduledoc """
  Loads project scope from the :project_name URL param.

  Uses `Projects.get_project_by_name/1` and `Scope.for_local_project/1`
  to build a complete scope with environment from the project's `local_path`.
  """

  import Plug.Conn

  alias CodeMySpec.Projects
  alias CodeMySpec.Users.Scope

  @behaviour Plug

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    name = conn.path_params["project_name"] || conn.params["project_name"]

    with {:ok, project} <- Projects.get_project_by_name(name),
         {:ok, scope} <- Scope.for_local_project(project) do
      conn
      |> assign(:current_scope, scope)
      |> assign(:working_dir, scope.cwd)
    else
      {:error, :not_found} ->
        text_halt(conn, 404, "Project not found: #{name}")

      {:error, :no_local_path} ->
        text_halt(conn, 400, "Project has no local_path set — run init first")

      {:error, reason} ->
        text_halt(conn, 400, "Failed to load project: #{inspect(reason)}")
    end
  end

  defp text_halt(conn, status, body) do
    conn
    |> put_resp_content_type("text/plain")
    |> send_resp(status, body)
    |> halt()
  end
end
