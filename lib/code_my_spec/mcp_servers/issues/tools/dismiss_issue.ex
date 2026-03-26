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

  schema do
    field :issue_id, :string, required: true, doc: "Issue ID to dismiss"
    field :reason, :string, required: true, doc: "Reason for dismissing the issue"
  end

  @impl true
  def execute(params, frame) do
    with {:ok, scope} <- Validators.validate_local_scope(frame, params),
         issue when not is_nil(issue) <- Issues.get_issue(scope, params.issue_id),
         {:ok, updated} <- Issues.dismiss_issue(scope, issue, params.reason) do
      {:reply, IssuesMapper.issue_updated_response(updated, "dismissed"), frame}
    else
      nil -> {:reply, IssuesMapper.not_found_error(), frame}
      {:error, %Ecto.Changeset{} = cs} -> {:reply, IssuesMapper.validation_error(cs), frame}
      {:error, reason} -> {:reply, IssuesMapper.error(reason), frame}
    end
  end
end
