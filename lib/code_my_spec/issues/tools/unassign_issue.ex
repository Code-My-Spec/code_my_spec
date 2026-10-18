defmodule CodeMySpec.Issues.Tools.UnassignIssue do
  @moduledoc false
  @behaviour CodeMySpec.Tools.Tool
  alias CodeMySpec.Agents
  alias CodeMySpec.Issues.Tools.Responses, as: IssuesMapper

  @impl true
  def name, do: "unassign_issue"

  @impl true
  def description do
    "Remove an issue from its working copy bag. Open tasks must be dispositioned first. Other assigned issues remain available."
  end

  @impl true
  def params do
    %{issue_id: {:required, {:meta, :string, [description: "Issue ID"]}}}
  end

  @impl true
  def call(params, context) do
    with {:ok, scope} <- CodeMySpec.Tools.project_scope(context),
         {:ok, issue} <- Agents.assign_issue_to_working_copy(scope, params.issue_id, nil) do
      IssuesMapper.issue_updated_response(issue, "updated")
    else
      {:error, :not_found} ->
        IssuesMapper.not_found_error()

      {:error, :no_team} ->
        IssuesMapper.error("The working copy has no coding or QA team.")

      {:error, reason} ->
        IssuesMapper.error(reason)
    end
  end
end
