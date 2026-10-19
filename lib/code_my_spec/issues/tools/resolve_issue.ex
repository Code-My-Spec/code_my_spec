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

  # Issue 9988f567: a coder finished d12aa283, called this directly, and the
  # issue went to resolved with its fix still unlanded on its copy -- nobody
  # could reopen it (resolved is terminal), so main had to file a second
  # issue just to carry the same commits through QA and promotion.
  #
  # Once an issue is assigned to a working copy it is in the fix_issue/
  # promote_issue track (`assign_issue_to_working_copy` sets `awaiting_role`
  # alongside it, every time), and landing is what resolves it --
  # `Qa.issue_fix_landed/3` calls `Issues.resolve_issue/3` directly, not this
  # tool, so that path is untouched by this guard.
  defp may_resolve(%{assigned_working_copy_id: copy_id}) when not is_nil(copy_id),
    do:
      {:error,
       "This issue is assigned to a working copy and its fix has not landed on main yet. " <>
         "Promote it with promote_issue -- the landing resolves the issue. Resolving it " <>
         "here would mark it done with the fix still unlanded."}

  defp may_resolve(_issue), do: :ok
end
