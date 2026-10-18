defmodule CodeMySpec.Issues.Tools.ResolveIssue do
  @moduledoc false
  @behaviour CodeMySpec.Tools.Tool

  alias CodeMySpec.Issues
  alias CodeMySpec.Issues.Tools.Responses, as: IssuesMapper
  alias CodeMySpec.TaskOwner

  @impl true
  def name, do: "resolve_issue"

  @impl true
  def description do
    """
    Resolves an accepted issue with a resolution description.

    Transitions the issue from accepted → resolved.
    Requires a resolution explaining how the issue was fixed.
    """
  end

  @impl true
  def params do
    %{
      issue_id: {:required, {:meta, :string, [description: "Issue ID to resolve"]}},
      resolution: {:required, {:meta, :string, [description: "How the issue was resolved"]}}
    }
  end

  @impl true
  def call(params, context) do
    with {:ok, scope} <- CodeMySpec.Tools.project_scope(context),
         issue when not is_nil(issue) <- Issues.get_issue(scope, params.issue_id),
         :ok <- may_resolve(issue),
         {:ok, updated} <- Issues.resolve_issue(scope, issue, params.resolution) do
      # Whoever was waiting on this can go. A task blocked on an issue is the
      # one blocker the system can clear for itself — a question or a tap_out
      # waits on a person, this waits on exactly the work that just landed.
      # Without it QA has to raise a tap-out to say "I am waiting on the bug I
      # filed", and a human has to answer it (af9e52c6).
      {:ok, _released} = TaskOwner.issue_closed(scope, updated)

      IssuesMapper.issue_updated_response(updated, "resolved")
    else
      nil -> IssuesMapper.not_found_error()
      {:error, %Ecto.Changeset{} = cs} -> IssuesMapper.validation_error(cs)
      {:error, reason} -> IssuesMapper.error(reason)
    end
  end

  defp may_resolve(%{story_id: story_id, assigned_working_copy_id: nil})
       when not is_nil(story_id),
       do:
         {:error,
          "Story issues must be submitted for shared story QA and completed through promotion."}

  defp may_resolve(_issue), do: :ok
end
