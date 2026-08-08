defmodule CodeMySpecLocalWeb.Plugs.WorkingDirScope do
  @moduledoc """
  Loads project scope for a local request.

  Delegates the "which project is this?" question to
  `Projects.resolve_local_project/1`: a configured sprite answers from its
  `:project_id`, and the desktop CLI answers by matching the working directory
  against `local_path`. The directory is still passed through as the
  environment root either way, since that is where the files actually are.
  """

  import Plug.Conn

  alias CodeMySpec.Projects
  alias CodeMySpec.Users.Scope

  @behaviour Plug

  @impl true
  def init(opts), do: opts

  @impl true
  def call(%{assigns: %{current_scope: %Scope{}}} = conn, _opts), do: conn

  def call(conn, _opts) do
    working_dir = conn.assigns[:working_dir]

    with {:ok, project} <- Projects.resolve_local_project(working_dir),
         {:ok, scope} <- Scope.for_local_project(project, working_dir) do
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
