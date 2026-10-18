defmodule CodeMySpec.Agents.Tools.ListAgentWork do
  @moduledoc false
  @behaviour CodeMySpec.Tools.Tool

  alias CodeMySpec.Agents.Main, as: MainAgent
  alias CodeMySpec.Agents.Tools.AgentWorkResponses, as: AgentWorkMapper

  @impl true
  def name, do: "list_agent_work"

  @impl true
  def description do
    """
    What every agent on this project is doing, across all its working copies.

    For each: the task it holds and the story behind it, when it last said
    anything, whether a turn is still running, what it is waiting on, and what is
    wrong on its checkout.

    Facts, not a verdict — whether an agent is stuck is your call to make from
    them.
    """
  end

  @impl true
  def params do
    %{}
  end

  @impl true
  def call(_params, context) do
    case work(context) do
      {:ok, work, off_agents} -> AgentWorkMapper.listing(work, off_agents)
      {:error, reason} -> AgentWorkMapper.error(reason)
    end
  end

  @impl true
  def script_result(_params, context) do
    with {:ok, work, _off_agents} <- work(context) do
      {:ok, Enum.map(work, &row/1)}
    end
  end

  defp work(context) do
    with {:ok, scope} <- CodeMySpec.Tools.project_scope(context) do
      {:ok, MainAgent.list_agent_work(scope), MainAgent.list_off_agents(scope)}
    end
  end

  defp row(w) do
    %{
      "agent_id" => w.agent_id,
      "role" => to_string(w.role),
      "agent_status" => to_string(w.agent_status),
      "working_copy_id" => w.working_copy_id,
      "working_copy_root" => w.working_copy_root,
      "issue_id" => w.issue_id,
      "team_free" => w.team_free?,
      "task_name" => w.task_name,
      "task_status" => w.task_status && to_string(w.task_status),
      "story_title" => w.story_title,
      "idle" => w.idle?,
      "tapped_out" => w.tapped_out?,
      "turn_in_flight" => w.turn_in_flight?
    }
  end
end
