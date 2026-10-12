defmodule CodeMySpec.McpServers.Issues.Tools.SetActiveIssue do
  @moduledoc "Prioritize an accepted issue already assigned to a working copy. This changes the team priority without removing other issues from its bag."
  use Anubis.Server.Component, type: :tool
  alias CodeMySpec.Agents
  alias CodeMySpec.McpServers.Issues.IssuesMapper
  alias CodeMySpec.McpServers.Validators

  schema do
    field :issue_id, :string, required: true, doc: "Issue ID"
    field :working_copy_id, :string, required: true, doc: "Working copy whose priority changes"
  end

  @impl true
  def execute(params, frame) do
    with {:ok, scope} <- Validators.validate_local_scope(frame, params),
         {:ok, issue} <- Agents.prioritize_issue(scope, params.working_copy_id, params.issue_id) do
      {:reply, IssuesMapper.issue_updated_response(issue, "updated"), frame}
    else
      {:error, :not_found} ->
        {:reply, IssuesMapper.not_found_error(), frame}

      {:error, :no_team} ->
        {:reply, IssuesMapper.error("The working copy has no coding or QA team."), frame}

      {:error, reason} ->
        {:reply, IssuesMapper.error(reason), frame}
    end
  end
end
