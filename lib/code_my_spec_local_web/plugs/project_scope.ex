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
        conn |> send_resp(404, "Project not found: #{name}") |> halt()

      {:error, :no_local_path} ->
        conn |> send_resp(400, "Project has no local_path set — run init first") |> halt()

      {:error, reason} ->
        conn |> send_resp(400, "Failed to load project: #{inspect(reason)}") |> halt()
    end
  end
end
