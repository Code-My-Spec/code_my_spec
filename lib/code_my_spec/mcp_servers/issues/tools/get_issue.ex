defmodule CodeMySpec.McpServers.Issues.Tools.GetIssue do
  @moduledoc """
  Gets a single issue by ID with full details.

  Accepts a full id or a unique prefix — the 8-character form every commit
  message, comment and issue body in this codebase uses.

  Use list_issues to find issue IDs.
  """

  use Anubis.Server.Component, type: :tool

  alias CodeMySpec.Issues
  alias CodeMySpec.McpServers.Issues.IssuesMapper
  alias CodeMySpec.McpServers.Validators

  schema do
    field :issue_id, :string,
      required: true,
      doc: "Issue ID, full or a unique prefix (use list_issues to find IDs)"
  end

  @impl true
  def execute(params, frame) do
    case Validators.validate_local_scope(frame, params) do
      {:ok, scope} -> reply(Issues.fetch_issue(scope, params.issue_id), params, frame)
      {:error, reason} -> {:reply, IssuesMapper.error(reason), frame}
    end
  end

  defp reply({:ok, issue}, _params, frame),
    do: {:reply, IssuesMapper.issue_get_response(issue), frame}

  defp reply(:not_found, _params, frame),
    do: {:reply, IssuesMapper.not_found_error(), frame}

  defp reply({:ambiguous, ids}, params, frame),
    do: {:reply, IssuesMapper.ambiguous_error(params.issue_id, ids), frame}
end
