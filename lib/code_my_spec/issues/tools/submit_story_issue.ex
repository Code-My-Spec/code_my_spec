defmodule CodeMySpec.Issues.Tools.SubmitStoryIssue do
  @moduledoc false
  @behaviour CodeMySpec.Tools.Tool

  alias CodeMySpec.Agents
  alias CodeMySpec.Issues
  alias CodeMySpec.Issues.Tools.Responses, as: IssuesMapper

  @impl true
  def name, do: "submit_story_issue"

  @impl true
  def description do
    "Submit a story-owned fix with the exact revision and validation evidence."
  end

  @impl true
  def params do
    %{
      revision:
        {:required,
         {:meta, :string, [description: "Exact committed revision containing the fix"]}},
      evidence:
        {:required, {:meta, :string, [description: "Fix description and validation evidence"]}},
      issue_id:
        {:required, {:meta, :string, [description: "Issue belonging to your assigned story"]}}
    }
  end

  @impl true
  def call(params, context) do
    with {:ok, scope} <- CodeMySpec.Tools.project_scope(context),
         {:ok, agent} <- owner(scope, context),
         issue when not is_nil(issue) <- Issues.get_issue(scope, params.issue_id),
         :ok <- assigned(scope, agent, issue),
         {:ok, updated} <-
           Issues.submit_story_issue(scope, issue, Map.put(params, :actor_id, agent.id)) do
      IssuesMapper.issue_updated_response(updated, "submitted for story QA")
    else
      nil -> IssuesMapper.not_found_error()
      {:error, %Ecto.Changeset{} = cs} -> IssuesMapper.validation_error(cs)
      {:error, reason} -> IssuesMapper.error(reason)
    end
  end

  defp owner(scope, context) do
    case context[:agent_id] do
      id when is_binary(id) -> Agents.fetch_agent(scope, id)
      _ -> {:error, :coding_agent_required}
    end
  end

  defp assigned(scope, %{role: :coding, retired_at: nil} = agent, issue) do
    story_id = Agents.Assignment.story_id(agent)

    if story_id == issue.story_id and not is_nil(story_id) and
         agent.working_copy_id == scope.active_working_copy_id,
       do: :ok,
       else: {:error, :story_not_assigned_to_agent}
  end

  defp assigned(_scope, _agent, _issue), do: {:error, :coding_agent_required}
end
