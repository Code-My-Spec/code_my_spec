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
  alias CodeMySpec.TaskOwner

  schema do
    field :issue_id, :string, required: true, doc: "Issue ID to resolve"
    field :resolution, :string, required: true, doc: "How the issue was resolved"
  end

  @impl true
  def execute(params, frame) do
    with {:ok, scope} <- Validators.validate_local_scope(frame, params),
         issue when not is_nil(issue) <- Issues.get_issue(scope, params.issue_id),
         {:ok, updated} <- Issues.resolve_issue(scope, issue, params.resolution) do
      # Whoever was waiting on this can go. A task blocked on an issue is the
      # one blocker the system can clear for itself — a question or a tap_out
      # waits on a person, this waits on exactly the work that just landed.
      # Without it QA has to raise a tap-out to say "I am waiting on the bug I
      # filed", and a human has to answer it (af9e52c6).
      {:ok, _released} = TaskOwner.release_issue_block(scope, updated.id)

      {:reply, IssuesMapper.issue_updated_response(updated, "resolved"), frame}
    else
      nil -> {:reply, IssuesMapper.not_found_error(), frame}
      {:error, %Ecto.Changeset{} = cs} -> {:reply, IssuesMapper.validation_error(cs), frame}
      {:error, reason} -> {:reply, IssuesMapper.error(reason), frame}
    end
  end
end
