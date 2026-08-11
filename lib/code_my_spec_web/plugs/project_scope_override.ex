defmodule CodeMySpecWeb.Plugs.ProjectScopeOverride do
  @moduledoc """
  Overrides the active project in scope when an `X-Project-ID` header is present.

  Runs after authentication (require_oauth_token) and checks for the header.
  If present, loads the project, verifies the user has account access, and
  overrides the scope. If absent, passes through unchanged for backward
  compatibility.
  """

  import Plug.Conn

  alias CodeMySpec.Accounts
  alias CodeMySpec.Harnesses
  alias CodeMySpec.Projects
  alias CodeMySpec.Projects.Project

  @behaviour Plug

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    scope = conn.assigns[:current_scope]

    case {scope, get_req_header(conn, "x-project-id")} do
      {nil, _} ->
        conn

      {_scope, []} ->
        conn

      {_scope, [""]} ->
        conn

      {scope, [project_id | _]} ->
        override_project(conn, scope, project_id)
    end
  end

  # `x-project-id` says which project; `x-harness-id` says which checkout of it.
  # Two worktrees of one project send the same project header, so without this
  # the far end cannot tell them apart and answers about both: `await_analysis`
  # reported 1141 credo problems to a copy that has 563, the rest belonging to a
  # checkout it cannot see and could not fix.
  #
  # Here rather than in `DeployKeyOrOAuth`, because this is the plug the harness
  # actually goes through — `/mcp/harness` runs `:mcp_protected`, which is
  # `require_oauth_token` and this. Two earlier attempts put it somewhere the
  # request never reaches.
  #
  # A harness belonging to another project is ignored rather than adopted, and
  # an absent or unreadable id leaves the scope unscoped: reading widely is a
  # bad answer, claiming another checkout's identity is a worse one.
  defp with_harness(scope, conn, project) do
    case get_req_header(conn, "x-harness-id") do
      [id | _] when is_binary(id) and id != "" -> adopt(scope, id, project)
      _ -> scope
    end
  end

  defp adopt(scope, id, project) do
    case Harnesses.fetch(id) do
      # `put_scope/2` rather than setting the id alone. Naming the working copy
      # and being able to reach it are two different things, and this set only
      # the first — so a tool over `/mcp/harness` knew exactly which checkout it
      # was talking about and could not read or write a byte of it. The channel
      # had always set all three; this had not, and the two drifted because
      # nothing made them the same call.
      {:ok, %{project_id: pid} = harness} when pid == project.id ->
        Harnesses.put_scope(scope, harness)

      _ ->
        scope
    end
  end

  defp override_project(conn, scope, project_id) do
    case Projects.get_project_by_id(project_id) do
      nil ->
        conn
        |> put_status(:not_found)
        |> Phoenix.Controller.json(%{error: "Project not found"})
        |> halt()

      %Project{} = project ->
        if Accounts.user_has_account_access?(scope, project.account_id) or
             framework_issue_create?(conn, project) do
          account = Accounts.get_account_by_id(project.account_id)

          updated_scope =
            %{
              scope
              | active_project: project,
                active_project_id: project.id,
                active_account: account,
                active_account_id: project.account_id
            }
            |> with_harness(conn, project)

          assign(conn, :current_scope, updated_scope)
        else
          conn
          |> put_status(:forbidden)
          |> Phoenix.Controller.json(%{error: "Access denied to project"})
          |> halt()
        end
    end
  end

  # Framework-scoped issues are friction with CodeMySpec itself — any
  # authenticated user may file one, even without access to the CodeMySpec
  # account. This relaxation is deliberately narrow: it applies ONLY to a POST
  # that creates a framework-scoped issue against the configured CodeMySpec
  # project. It does NOT grant the user access to that project for any other
  # resource served by this pipeline (stories, uploads, permissions, etc.).
  defp framework_issue_create?(conn, %Project{id: project_id}) do
    conn.method == "POST" and
      conn.path_info == ["api", "issues"] and
      project_id == code_my_spec_project_id() and
      framework_scoped?(conn.params)
  end

  defp framework_scoped?(%{"issue" => %{"scope" => "framework"}}), do: true
  defp framework_scoped?(_), do: false

  defp code_my_spec_project_id do
    Application.get_env(:code_my_spec, :code_my_spec_project_id)
  end
end
