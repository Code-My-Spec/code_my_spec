defmodule CodeMySpec.Issues.Tools.UnassignIssueFromWorkingCopy do
  @moduledoc false
  @behaviour CodeMySpec.Tools.Tool

  alias CodeMySpec.Agents
  alias CodeMySpec.Issues
  alias CodeMySpec.Issues.Tools.Responses, as: IssuesMapper

  @impl true
  def name, do: "unassign_issue_from_working_copy"

  @impl true
  def description do
    "Remove an issue from its working copy without resolving it."
  end

  @impl true
  def params do
    %{
      working_copy_id:
        {:required, {:meta, :string, [description: "Copy currently holding the issue"]}},
      issue_id: {:required, {:meta, :string, [description: "Issue to remove"]}}
    }
  end

  @impl true
  def call(params, context) do
    with {:ok, scope} <- CodeMySpec.Tools.project_scope(context),
         %{assigned_working_copy_id: copy_id} <- Issues.get_issue(scope, params.issue_id),
         true <- copy_id == params.working_copy_id or is_nil(copy_id),
         {:ok, issue} <- Agents.assign_issue_to_working_copy(scope, params.issue_id, nil) do
      IssuesMapper.issue_updated_response(issue, "unassigned")
    else
      nil -> IssuesMapper.not_found_error()
      false -> IssuesMapper.error(:assigned_elsewhere)
      {:error, reason} -> IssuesMapper.error(reason)
    end
  end
end
