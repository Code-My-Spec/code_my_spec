defmodule CodeMySpec.McpServers.MainAgent.Tools.ListAgentWork do
  @moduledoc """
  What every agent on this project is doing, across all its working copies.

  For each: the task it holds and the story behind it, when it last said
  anything, whether a turn is still running, what it is waiting on, and what is
  wrong on its checkout.

  Facts, not a verdict — whether an agent is stuck is your call to make from
  them.
  """

  # Not folded into `list_agents`, which answers "what is running and where".
  # That is the fleet's lifecycle and is what `start_agent` and `turn_off_agent`
  # want; this is four more facts per agent that none of those callers need.
  #
  # No computed status, and that is criterion 3275 rather than an oversight. A
  # silence threshold that produces "stalled" calls a streaming agent dead and a
  # tapped-out one broken, and once the verdict is printed the parts it came
  # from are gone.
  #
  # Comments rather than moduledoc past the first paragraphs: the moduledoc is
  # advertised to every agent at connect and `SpineTest` caps that payload.

  use Anubis.Server.Component, type: :tool

  @behaviour CodeMySpec.McpServers.ScriptResult

  alias CodeMySpec.Agents.Main, as: MainAgent
  alias CodeMySpec.McpServers.MainAgent.AgentWorkMapper
  alias CodeMySpec.McpServers.Validators

  schema do
  end

  @impl true
  def execute(_params, frame) do
    case work(frame) do
      {:ok, work, off_agents} -> {:reply, AgentWorkMapper.listing(work, off_agents), frame}
      {:error, reason} -> {:reply, AgentWorkMapper.error(reason), frame}
    end
  end

  @impl CodeMySpec.McpServers.ScriptResult
  def script_result(_params, frame) do
    with {:ok, work, _off_agents} <- work(frame) do
      {:ok, Enum.map(work, &row/1)}
    end
  end

  defp work(frame) do
    with {:ok, scope} <- Validators.validate_local_scope(frame) do
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
