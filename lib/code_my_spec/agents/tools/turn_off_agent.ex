defmodule CodeMySpec.Agents.Tools.TurnOffAgent do
  @moduledoc false
  @behaviour CodeMySpec.Tools.Tool

  alias CodeMySpec.Agents
  alias CodeMySpec.Agents.Tools.Responses, as: AgentsMapper
  alias CodeMySpec.Utils.MapAccess

  @impl true
  def name, do: "turn_off_agent"

  @impl true
  def description do
    """
    Turn one agent off.

    The only way to stop an agent on purpose (39af5611), and it replaced
    `stop_agent` so there is one. Off is a shutdown, not a note: the process is
    ended, and until somebody calls `turn_on_agent` nothing is delivered to it
    and nothing restarts it. Who turned it off, when, and the optional reason are
    shown to the main agent in `check_in` and `list_agent_work`.

    One agent, and only one. A stop that reaps the whole tree, or kills by name
    and catches a sibling, is worse than having no stop at all.
    """
  end

  @impl true
  def params do
    %{
      reason:
        {:meta, :string,
         [description: "Optional. Why, e.g. \"held until the spec-binding fix lands\"."]},
      agent_id: {:required, {:meta, :string, [description: "Id of the agent to turn off"]}}
    }
  end

  @impl true
  def call(params, context) do
    with {:ok, scope} <- CodeMySpec.Tools.project_scope(context),
         {:ok, agent} <-
           Agents.turn_off_agent(scope, MapAccess.get(params, :agent_id),
             by: Agents.actor(scope, context[:agent_id]),
             reason: MapAccess.get(params, :reason)
           ) do
      AgentsMapper.turned_off(agent)
    else
      {:error, reason} -> AgentsMapper.error(reason, nil)
    end
  end
end
