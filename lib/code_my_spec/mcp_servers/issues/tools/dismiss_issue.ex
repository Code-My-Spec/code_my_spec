defmodule CodeMySpec.McpServers.Issues.Tools.DismissIssue do
  @moduledoc """
  Dismisses an incoming issue with a reason.

  Transitions the issue from incoming → dismissed.
  Requires a reason explaining why the issue was dismissed.
  """

  use Anubis.Server.Component, type: :tool

  alias CodeMySpec.Issues
  alias CodeMySpec.McpServers.Issues.IssuesMapper
  alias CodeMySpec.McpServers.Validators
  alias CodeMySpec.TaskOwner

  schema do
    field :issue_id, :string, required: true, description: "Issue ID to dismiss"
    field :reason, :string, required: true, description: "Reason for dismissing the issue"
  end

  @impl true
  def execute(params, frame) do
    with {:ok, scope} <- Validators.validate_local_scope(frame, params),
         issue when not is_nil(issue) <- Issues.get_issue(scope, params.issue_id),
         {:ok, updated} <- Issues.dismiss_issue(scope, issue, params.reason) do
      # A dismissed issue is as closed as a resolved one; whoever waited on it
      # can go (545653ad).
      {:ok, _released} = TaskOwner.issue_closed(scope, updated)

      {:reply, IssuesMapper.issue_updated_response(updated, "dismissed"), frame}
    else
      nil -> {:reply, IssuesMapper.not_found_error(), frame}
      {:error, %Ecto.Changeset{} = cs} -> {:reply, IssuesMapper.validation_error(cs), frame}
      {:error, reason} -> {:reply, IssuesMapper.error(reason), frame}
    end
  end
end
