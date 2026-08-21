defmodule CodeMySpec.McpServers.Issues.Tools.CreateIssue do
  @moduledoc """
  Record an issue against the project (`scope: app`) or against
  CodeMySpec itself (`scope: framework`).

  If you encounter undocumented config, a looping hook, a tool error,
  or contradictory prompts inside CodeMySpec, your FIRST call is
  `create_issue` with `scope: framework` — before asking the human
  operator and before working around the problem. The framework is
  the system you are operating inside; friction with it is a
  first-class issue, not a question to escalate or a workaround to
  invent.

  Trigger examples (use `scope: framework`):

  - Confusing or contradictory prompts/instructions
  - Looping stop hooks or stuck workflows
  - Errors from tools or MCP servers
  - Missing, broken, or poorly documented tools
  - Suggestions for improvements to the system

  For project-side bugs and feature gaps (the app under development,
  not CodeMySpec), use `scope: app` (the default).

  Issues land as `incoming` and are triaged by the human operator. Be
  specific in your description — include the exact error message, what
  you were doing, and what you expected to happen.
  """

  use Anubis.Server.Component, type: :tool

  require Logger

  alias CodeMySpec.Issues
  alias CodeMySpec.McpServers.Issues.IssuesMapper
  alias CodeMySpec.McpServers.Validators
  alias CodeMySpec.Projects
  alias CodeMySpec.Projects.Project

  schema do
    field :title, :string, required: true, doc: "Short issue title"

    field :severity, :string,
      required: true,
      doc: "Issue severity: critical, high, medium, low, or info"

    field :description, :string,
      required: true,
      doc: "Detailed description of the issue including steps to reproduce if applicable"

    field :scope, :string, doc: "Issue scope: app (default), qa, docs, or framework"

    field :story_id, :integer, doc: "Related user story ID, if applicable"

    field :source_path, :string, doc: "File path where the issue was found, if applicable"
  end

  @impl true
  def execute(params, frame) do
    with {:ok, scope} <- Validators.validate_local_scope(frame, params),
         attrs <- build_attrs(params),
         {:ok, issue} <- create(scope, attrs) do
      {:reply, IssuesMapper.issue_created_response(issue, filed_where(scope, issue)), frame}
    else
      {:error, changeset = %Ecto.Changeset{}} ->
        {:reply, IssuesMapper.validation_error(changeset), frame}

      {:error, reason} ->
        {:reply, IssuesMapper.error(reason), frame}
    end
  end

  # Framework issues are friction with CodeMySpec, so they belong to CodeMySpec's
  # project — not to whichever project the agent that hit them happens to be
  # working in.
  #
  # This was already true of the REST path an installed CLI files through:
  # `Plugs.ProjectScopeOverride.framework_issue_create?/2` lets any authenticated
  # user POST a framework-scoped issue against the configured CodeMySpec project
  # even without access to it, and the CLI sets `x-project-id` to that project.
  # The MCP tool never went through that plug — it resolves the caller's own
  # scope and wrote with it — so an agent working in another project filed its
  # framework issues into that project, where nobody maintaining the framework
  # will ever look and where `list_issues` in the CodeMySpec project cannot see
  # them.
  #
  # Measured 2026-08-21: an agent in a `broken_oaths` checkout filed a framework
  # issue about the harness and it landed on project `49760b8b-…`.
  #
  # Every other scope is unchanged and writes where the caller is. `app`, `qa`
  # and `docs` are about the project being built, which is exactly the caller's.
  defp create(scope, %{scope: :framework} = attrs), do: framework_issue(scope, attrs)
  defp create(scope, attrs), do: Issues.create_issue(scope, attrs)

  # `report_framework_issue/3` rather than a scope built here: it forces
  # `scope: framework` and defaults the source, and it is what the deploy-key
  # intake already calls, so both routes file identically.
  defp framework_issue(scope, attrs) do
    case framework_project() do
      %Project{} = project ->
        Issues.report_framework_issue(project.account_id, project.id, attrs)

      nil ->
        # No configured CodeMySpec project — `config/test.exs` sets none, and an
        # install that has not been told which project is CodeMySpec cannot know.
        # Filed where the caller is rather than refused: a framework issue in the
        # wrong project is recoverable, and losing the report is not.
        Logger.warning(
          "[CreateIssue] no :code_my_spec_project_id is configured, so this framework " <>
            "issue is filed against #{scope.active_project_id} — the project the agent " <>
            "is working in — rather than against CodeMySpec's."
        )

        Issues.create_issue(scope, attrs)
    end
  end

  defp framework_project do
    case Application.get_env(:code_my_spec, :code_my_spec_project_id) do
      id when is_binary(id) and id != "" -> Projects.get_project_by_id(id)
      _ -> nil
    end
  end

  # Only when it went somewhere other than here, which is the case a reader
  # cannot otherwise tell from the reply.
  defp filed_where(%{active_project_id: same}, %{project_id: same}), do: nil

  defp filed_where(_scope, %{project_id: project_id}) do
    "Filed against CodeMySpec's own project (#{project_id}), not the project you are " <>
      "working in — framework issues are friction with CodeMySpec itself. `list_issues` " <>
      "here will not show it."
  end

  defp build_attrs(params) do
    params
    |> Map.put(:status, :incoming)
    |> maybe_atomize(:severity)
    |> maybe_atomize(:scope)
  end

  defp maybe_atomize(map, key) do
    case Map.get(map, key) do
      val when is_binary(val) ->
        try do
          Map.put(map, key, String.to_existing_atom(val))
        rescue
          ArgumentError -> map
        end

      _ ->
        map
    end
  end
end
