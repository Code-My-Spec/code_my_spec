defmodule CodeMySpec.McpServers.Issues.Tools.AcceptIssue do
  @moduledoc """
  Accepts an incoming issue for triage.

  Transitions the issue from incoming → accepted.
  """

  use Anubis.Server.Component, type: :tool

  alias CodeMySpec.Issues
  alias CodeMySpec.McpServers.Issues.IssuesMapper
  alias CodeMySpec.McpServers.Validators

  schema do
    field :issue_id, :string, required: true, doc: "Issue ID to accept"
  end

  @impl true
  def execute(params, frame) do
    with {:ok, scope} <- Validators.validate_local_scope(frame, params),
         issue when not is_nil(issue) <- Issues.get_issue(scope, params.issue_id),
         {:ok, updated} <- Issues.accept_issue(scope, issue) do
      {:reply, IssuesMapper.issue_updated_response(updated, "accepted"), frame}
    else
      nil -> {:reply, IssuesMapper.not_found_error(), frame}
      {:error, %Ecto.Changeset{} = cs} -> {:reply, IssuesMapper.validation_error(cs), frame}
      {:error, reason} -> {:reply, IssuesMapper.error(reason), frame}
    end
  end
end
