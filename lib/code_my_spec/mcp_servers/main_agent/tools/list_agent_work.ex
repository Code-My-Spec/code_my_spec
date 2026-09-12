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
  # That is the fleet's lifecycle and is what `start_agent` and `stop_agent`
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

  alias CodeMySpec.MainAgent
  alias CodeMySpec.McpServers.MainAgent.AgentWorkMapper
  alias CodeMySpec.McpServers.Validators

  schema do
  end

  @impl true
  def execute(_params, frame) do
    case Validators.validate_local_scope(frame) do
      {:ok, scope} ->
        {:reply, AgentWorkMapper.listing(MainAgent.list_agent_work(scope)), frame}

      {:error, reason} ->
        {:reply, AgentWorkMapper.error(reason), frame}
    end
  end
end
