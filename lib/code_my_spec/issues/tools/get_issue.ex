defmodule CodeMySpec.Issues.Tools.GetIssue do
  @moduledoc false
  @behaviour CodeMySpec.Tools.Tool

  alias CodeMySpec.Issues
  alias CodeMySpec.Issues.Tools.Responses, as: IssuesMapper

  @impl true
  def name, do: "get_issue"

  @impl true
  def description do
    """
    Gets a single issue by ID with full details.

    Accepts a full id or a unique prefix — the 8-character form every commit
    message, comment and issue body in this codebase uses.

    Use list_issues to find issue IDs.
    """
  end

  @impl true
  def params do
    %{
      issue_id:
        {:required,
         {:meta, :string,
          [description: "Issue ID, full or a unique prefix (use list_issues to find IDs)"]}}
    }
  end

  @impl true
  def call(params, context) do
    case CodeMySpec.Tools.project_scope(context) do
      {:ok, scope} -> reply(Issues.fetch_issue(scope, params.issue_id), params, context)
      {:error, reason} -> IssuesMapper.error(reason)
    end
  end

  defp reply({:ok, issue}, _params, _context),
    do: IssuesMapper.issue_get_response(issue)

  defp reply(:not_found, _params, _context),
    do: IssuesMapper.not_found_error()

  defp reply({:ambiguous, ids}, params, _context),
    do: IssuesMapper.ambiguous_error(params.issue_id, ids)
end
