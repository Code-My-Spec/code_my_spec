defmodule CodeMySpec.McpServers.Issues.Tools.UnassignIssueFromWorkingCopy do
  @moduledoc "Remove an issue from its working copy without resolving it."
  use Anubis.Server.Component, type: :tool

  alias CodeMySpec.Agents
  alias CodeMySpec.Issues
  alias CodeMySpec.McpServers.Issues.IssuesMapper
  alias CodeMySpec.McpServers.Validators

  schema do
    field :issue_id, :string, required: true, description: "Issue to remove"
    field :working_copy_id, :string, required: true, description: "Copy currently holding the issue"
  end

  @impl true
  def execute(params, frame) do
    with {:ok, scope} <- Validators.validate_local_scope(frame),
         %{assigned_working_copy_id: copy_id} <- Issues.get_issue(scope, params.issue_id),
         true <- copy_id == params.working_copy_id or is_nil(copy_id),
         {:ok, issue} <- Agents.assign_issue_to_working_copy(scope, params.issue_id, nil) do
      {:reply, IssuesMapper.issue_updated_response(issue, "unassigned"), frame}
    else
      nil -> {:reply, IssuesMapper.not_found_error(), frame}
      false -> {:reply, IssuesMapper.error(:assigned_elsewhere), frame}
      {:error, reason} -> {:reply, IssuesMapper.error(reason), frame}
    end
  end
end
