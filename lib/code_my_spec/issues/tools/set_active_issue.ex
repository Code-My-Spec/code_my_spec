defmodule CodeMySpec.Issues.Tools.SetActiveIssue do
  @moduledoc false
  @behaviour CodeMySpec.Tools.Tool
  alias CodeMySpec.Agents
  alias CodeMySpec.Issues.Tools.Responses, as: IssuesMapper

  @impl true
  def name, do: "set_active_issue"

  @impl true
  def description do
    "Prioritize an accepted issue already assigned to a working copy. This changes the team priority without removing other issues from its bag."
  end

  @impl true
  def params do
    %{
      working_copy_id:
        {:required, {:meta, :string, [description: "Working copy whose priority changes"]}},
      issue_id: {:required, {:meta, :string, [description: "Issue ID"]}}
    }
  end

  @impl true
  def call(params, context) do
    with {:ok, scope} <- CodeMySpec.Tools.project_scope(context),
         {:ok, issue} <- Agents.prioritize_issue(scope, params.working_copy_id, params.issue_id) do
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
