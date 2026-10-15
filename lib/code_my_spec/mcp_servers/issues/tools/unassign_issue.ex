defmodule CodeMySpec.McpServers.Issues.Tools.UnassignIssue do
  @moduledoc "Remove an issue from its working copy bag. Open tasks must be dispositioned first. Other assigned issues remain available."
  use Anubis.Server.Component, type: :tool
  alias CodeMySpec.Agents
  alias CodeMySpec.McpServers.Issues.IssuesMapper
  alias CodeMySpec.McpServers.Validators

  schema do
    field :issue_id, :string, required: true, description: "Issue ID"
  end

  @impl true
  def execute(params, frame) do
    with {:ok, scope} <- Validators.validate_local_scope(frame, params),
         {:ok, issue} <- Agents.assign_issue_to_working_copy(scope, params.issue_id, nil) do
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
