defmodule CodeMySpec.Agents.Tools.TurnOnAgent do
  @moduledoc false
  @behaviour CodeMySpec.Tools.Tool

  alias CodeMySpec.Agents
  alias CodeMySpec.Agents.Tools.Responses, as: AgentsMapper
  alias CodeMySpec.Utils.MapAccess

  @impl true
  def name, do: "turn_on_agent"

  @impl true
  def description do
    """
    Turn an agent that is off back on, and start it.

    The only way back from `turn_off_agent` (39af5611). `start_agent`,
    `restart_agent` and `message_agent` refuse an agent that is off rather than
    turning it on, so turning one on is always a decision somebody made here.
    Somebody turned it off for a reason: `list_agent_work` shows it. Only turn it
    on when that reason no longer applies.
    """
  end

  @impl true
  def params do
    %{agent_id: {:required, {:meta, :string, [description: "Id of the agent to turn on"]}}}
  end

  @impl true
  def call(params, context) do
    with {:ok, scope} <- CodeMySpec.Tools.project_scope(context),
         {:ok, agent} <- Agents.turn_on_agent(scope, MapAccess.get(params, :agent_id)) do
      AgentsMapper.turned_on(agent)
    else
      {:error, reason} -> AgentsMapper.error(reason, nil)
    end
  end
end
