defmodule CodeMySpec.McpServers.Agents.Tools.TurnOnAgent do
  @moduledoc """
  Turn an agent that is off back on, and start it.

  The only way back from `turn_off_agent` (39af5611). `start_agent`,
  `restart_agent` and `message_agent` refuse an agent that is off rather than
  turning it on, so turning one on is always a decision somebody made here.
  Somebody turned it off for a reason: `list_agent_work` shows it. Only turn it
  on when that reason no longer applies.
  """

  use Anubis.Server.Component, type: :tool

  alias CodeMySpec.Agents
  alias CodeMySpec.McpServers.Agents.AgentsMapper
  alias CodeMySpec.McpServers.Validators
  alias CodeMySpec.Utils.MapAccess

  schema do
    field :agent_id, :string, required: true, description: "Id of the agent to turn on"
  end

  @impl true
  def execute(params, frame) do
    with {:ok, scope} <- Validators.validate_local_scope(frame, params),
         {:ok, agent} <- Agents.turn_on_agent(scope, MapAccess.get(params, :agent_id)) do
      {:reply, AgentsMapper.turned_on(agent), frame}
    else
      {:error, reason} -> {:reply, AgentsMapper.error(reason, nil), frame}
    end
  end
end
