defmodule CodeMySpec.Issues.Tools.DismissIssue do
  @moduledoc false
  @behaviour CodeMySpec.Tools.Tool

  alias CodeMySpec.Issues
  alias CodeMySpec.Issues.Tools.Responses, as: IssuesMapper
  alias CodeMySpec.TaskOwner

  @impl true
  def name, do: "dismiss_issue"

  @impl true
  def description do
    """
    Dismisses an incoming issue with a reason.

    Transitions the issue from incoming → dismissed.
    Requires a reason explaining why the issue was dismissed.
    """
  end

  @impl true
  def params do
    %{
      reason: {:required, {:meta, :string, [description: "Reason for dismissing the issue"]}},
      issue_id: {:required, {:meta, :string, [description: "Issue ID to dismiss"]}}
    }
  end

  @impl true
  def call(params, context) do
    with {:ok, scope} <- CodeMySpec.Tools.project_scope(context),
         issue when not is_nil(issue) <- Issues.get_issue(scope, params.issue_id),
         {:ok, updated} <- Issues.dismiss_issue(scope, issue, params.reason) do
      # A dismissed issue is as closed as a resolved one; whoever waited on it
      # can go (545653ad).
      {:ok, _released} = TaskOwner.issue_closed(scope, updated)

      IssuesMapper.issue_updated_response(updated, "dismissed")
    else
      nil -> IssuesMapper.not_found_error()
      {:error, %Ecto.Changeset{} = cs} -> IssuesMapper.validation_error(cs)
      {:error, reason} -> IssuesMapper.error(reason)
    end
  end
end
