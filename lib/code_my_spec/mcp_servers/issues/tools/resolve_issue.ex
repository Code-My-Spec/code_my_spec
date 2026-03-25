defmodule CodeMySpec.McpServers.Issues.Tools.ResolveIssue do
  @moduledoc """
  Resolves an accepted issue with a resolution description.

  Transitions the issue from accepted → resolved.
  Requires a resolution explaining how the issue was fixed.
  """

  use Anubis.Server.Component, type: :tool

  alias CodeMySpec.Issues
  alias CodeMySpec.McpServers.Issues.IssuesMapper
  alias CodeMySpec.McpServers.Validators

  schema do
    field :issue_id, :string, required: true, doc: "Issue ID to resolve"
    field :resolution, :string, required: true, doc: "How the issue was resolved"
  end

  @impl true
  def execute(params, frame) do
    with {:ok, scope} <- Validators.validate_scope(frame),
         issue when not is_nil(issue) <- Issues.get_issue(scope, params.issue_id),
         {:ok, updated} <- Issues.resolve_issue(scope, issue, params.resolution) do
      {:reply, IssuesMapper.issue_updated_response(updated, "resolved"), frame}
    else
      nil -> {:reply, IssuesMapper.not_found_error(), frame}
      {:error, %Ecto.Changeset{} = cs} -> {:reply, IssuesMapper.validation_error(cs), frame}
      {:error, reason} -> {:reply, IssuesMapper.error(reason), frame}
    end
  end
end
