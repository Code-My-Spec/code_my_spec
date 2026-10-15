defmodule CodeMySpec.McpServers.Issues.Tools.SubmitStoryIssue do
  @moduledoc "Submit a story-owned fix with the exact revision and validation evidence."
  use Anubis.Server.Component, type: :tool

  alias CodeMySpec.Agents
  alias CodeMySpec.Issues
  alias CodeMySpec.McpServers.Issues.IssuesMapper
  alias CodeMySpec.McpServers.Validators

  schema do
    field(:issue_id, :string, required: true, description: "Issue belonging to your assigned story")
    field(:revision, :string, required: true, description: "Exact committed revision containing the fix")
    field(:evidence, :string, required: true, description: "Fix description and validation evidence")
  end

  @impl true
  def execute(params, frame) do
    with {:ok, scope} <- Validators.validate_local_scope(frame, params),
         {:ok, agent} <- owner(scope, frame),
         issue when not is_nil(issue) <- Issues.get_issue(scope, params.issue_id),
         :ok <- assigned(scope, agent, issue),
         {:ok, updated} <-
           Issues.submit_story_issue(scope, issue, Map.put(params, :actor_id, agent.id)) do
      {:reply, IssuesMapper.issue_updated_response(updated, "submitted for story QA"), frame}
    else
      nil -> {:reply, IssuesMapper.not_found_error(), frame}
      {:error, %Ecto.Changeset{} = cs} -> {:reply, IssuesMapper.validation_error(cs), frame}
      {:error, reason} -> {:reply, IssuesMapper.error(reason), frame}
    end
  end

  defp owner(scope, frame) do
    case frame.assigns[:agent_id] do
      id when is_binary(id) -> Agents.fetch_agent(scope, id)
      _ -> {:error, :coding_agent_required}
    end
  end

  defp assigned(scope, %{role: :coding, retired_at: nil} = agent, issue) do
    if agent.story_id == issue.story_id and not is_nil(agent.story_id) and
         agent.working_copy_id == scope.active_working_copy_id,
       do: :ok,
       else: {:error, :story_not_assigned_to_agent}
  end

  defp assigned(_scope, _agent, _issue), do: {:error, :coding_agent_required}
end
