defmodule CodeMySpec.McpServers.Agents.Tools.TurnOffAgent do
  @moduledoc """
  Turn one agent off.

  The only way to stop an agent on purpose (39af5611), and it replaced
  `stop_agent` so there is one. Off is a shutdown, not a note: the process is
  ended, and until somebody calls `turn_on_agent` nothing is delivered to it
  and nothing restarts it. Who turned it off, when, and the optional reason are
  shown to the main agent in `check_in` and `list_agent_work`.

  One agent, and only one. A stop that reaps the whole tree, or kills by name
  and catches a sibling, is worse than having no stop at all.
  """

  use Anubis.Server.Component, type: :tool

  alias CodeMySpec.Agents
  alias CodeMySpec.McpServers.Agents.AgentsMapper
  alias CodeMySpec.McpServers.Validators
  alias CodeMySpec.Utils.MapAccess

  schema do
    field :agent_id, :string, required: true, doc: "Id of the agent to turn off"

    field :reason, :string, doc: ~s(Optional. Why, e.g. "held until the spec-binding fix lands".)
  end

  @impl true
  def execute(params, frame) do
    with {:ok, scope} <- Validators.validate_local_scope(frame, params),
         {:ok, agent} <-
           Agents.turn_off_agent(scope, MapAccess.get(params, :agent_id),
             by: Agents.actor(scope, frame.assigns[:agent_id]),
             reason: MapAccess.get(params, :reason)
           ) do
      {:reply, AgentsMapper.turned_off(agent), frame}
    else
      {:error, reason} -> {:reply, AgentsMapper.error(reason, nil), frame}
    end
  end
end
