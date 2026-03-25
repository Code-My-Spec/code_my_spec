defmodule CodeMySpec.McpServers.Issues.Tools.GetIssue do
  @moduledoc """
  Gets a single issue by ID with full details.

  Use list_issues to find issue IDs.
  """

  use Anubis.Server.Component, type: :tool

  alias CodeMySpec.Issues
  alias CodeMySpec.McpServers.Issues.IssuesMapper
  alias CodeMySpec.McpServers.Validators

  schema do
    field :issue_id, :string, required: true, doc: "Issue ID (use list_issues to find IDs)"
  end

  @impl true
  def execute(params, frame) do
    with {:ok, scope} <- Validators.validate_scope(frame),
         issue when not is_nil(issue) <- Issues.get_issue(scope, params.issue_id) do
      {:reply, IssuesMapper.issue_get_response(issue), frame}
    else
      nil -> {:reply, IssuesMapper.not_found_error(), frame}
      {:error, reason} -> {:reply, IssuesMapper.error(reason), frame}
    end
  end
end
