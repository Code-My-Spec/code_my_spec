defmodule CodeMySpecWeb.Plugs.ProjectScopeOverride do
  @moduledoc """
  Which working copy — and therefore which project — a request is about.

  `X-Harness-Id` is the answer. A harness *is* a working copy and it belongs to
  exactly one project, so it settles both questions at once and cannot
  contradict itself.

  `X-Project-ID` is still accepted, for callers that only have one. It is the
  coarser key: two worktrees of one project send the same value, so on its own
  the far end cannot tell them apart and answers about both — `await_analysis`
  reported 1141 credo problems to a copy that has 563, the rest belonging to a
  checkout it could not see and could not fix.

  Sending both is allowed and is what the plugin did. It is also the shape that
  invites the two to disagree: a harness id from one checkout beside a project
  id from another project. When both arrive the harness wins and the project
  header is ignored, because the more specific of two answers to the same
  question is the one to keep.

  Runs after authentication. Absent both headers, it passes through unchanged.
  """

  import Plug.Conn

  require Logger

  alias CodeMySpec.Accounts
  alias CodeMySpec.Projects
  alias CodeMySpec.Projects.Project
  alias CodeMySpec.WorkingCopies

  @behaviour Plug

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    case conn.assigns[:current_scope] do
      nil ->
        conn

      scope ->
        raw_harness_id = header(conn, "x-harness-id")
        raw_project_id = header(conn, "x-project-id")

        if "mcp" in conn.path_info do
          Logger.warning(
            "[ProjectScopeOverride][DIAG] path=#{conn.request_path} " <>
              "raw_x_harness_id=#{inspect(raw_harness_id)} " <>
              "raw_x_project_id=#{inspect(raw_project_id)} " <>
              "path_params=#{inspect(conn.path_params)} " <>
              "pre_override_working_copy_id=#{inspect(scope.active_working_copy_id)}"
          )
        end

        override(conn, scope, raw_harness_id, raw_project_id)
    end
  end

  # The harness first, and alone if that is all there is. It names the working
  # copy *and* the project it belongs to, so a caller that has one needs nothing
  # else — and cannot send a pair that disagrees.
  defp override(conn, scope, working_copy_id, _project_id) when is_binary(working_copy_id) do
    case WorkingCopies.fetch(working_copy_id) do
      {:ok, harness} ->
        override_project(conn, scope, harness.project_id, harness)

      _ ->
        # Not quietly falling back to the project header. An id this server does
        # not know is a client pointed somewhere wrong, and answering about a
        # project it happens to also name is how a wrong address becomes a
        # plausible answer about somebody else's checkout.
        conn
        |> put_status(:not_found)
        |> Phoenix.Controller.json(%{error: "Unknown harness #{working_copy_id}"})
        |> halt()
    end
  end

  defp override(conn, scope, _working_copy_id, project_id) when is_binary(project_id),
    do: override_project(conn, scope, project_id, nil)

  defp override(conn, _scope, _working_copy_id, _project_id), do: conn

  defp header(conn, name) do
    case get_req_header(conn, name) do
      # An unexpanded shell variable is not an id. The plugin interpolates these
      # from the environment, and an unset one arrives literally.
      ["$" <> _ | _] -> nil
      [value | _] when is_binary(value) and value != "" -> value
      _ -> nil
    end
  end

  # A harness resolved above, adopted only if it really belongs to this project.
  # A mismatch is ignored rather than adopted: reading widely is a bad answer,
  # claiming another checkout's identity is a worse one.
  #
  # `put_scope/2` rather than setting the id alone. Naming the working copy and
  # being able to reach it are two different things, and this set only the first
  # — so a tool over `/mcp/harness` knew exactly which checkout it was talking
  # about and could not read or write a byte of it. The channel had always set
  # all three; this had not, and the two drifted because nothing made them the
  # same call.
  defp with_harness(scope, %{project_id: pid} = harness, project) when pid == project.id,
    do: WorkingCopies.put_scope(scope, harness)

  defp with_harness(scope, _harness, _project), do: scope

  defp override_project(conn, scope, project_id, harness) do
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
            |> with_harness(harness, project)

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
