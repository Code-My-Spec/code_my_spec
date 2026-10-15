defmodule CodeMySpec.McpServers.Agents.Tools.RetireAgent do
  @moduledoc """
  Retire an agent: end it for good and free its seat.

  Not the same as `turn_off_agent` (39af5611). Off keeps the agent's seat and
  can be undone with `turn_on_agent`; retired cannot be undone. A retired agent
  never runs or receives anything again, and `start_agent` may put a new agent
  in its seat. Its conversation stays for history.
  """

  use Anubis.Server.Component, type: :tool

  alias CodeMySpec.Agents
  alias CodeMySpec.McpServers.Agents.AgentsMapper
  alias CodeMySpec.McpServers.Validators
  alias CodeMySpec.Utils.MapAccess

  schema do
    field :agent_id, :string, required: true, description: "Id of the agent to retire"
    field :reason, :string, description: "Optional. Why it is being retired."
  end

  @impl true
  def execute(params, frame) do
    case Validators.validate_local_scope(frame, params) do
      {:ok, scope} ->
        scope
        |> Agents.retire_agent(MapAccess.get(params, :agent_id),
          by: Agents.actor(scope, frame.assigns[:agent_id]),
          reason: MapAccess.get(params, :reason)
        )
        |> reply(frame)

      {:error, reason} ->
        reply({:error, reason}, frame)
    end
  end

  defp reply({:ok, agent}, frame), do: {:reply, AgentsMapper.retired(agent), frame}

  defp reply({:ok, agent, {:unreachable, machine}}, frame),
    do: {:reply, AgentsMapper.retired(agent, machine), frame}

  defp reply({:error, reason}, frame), do: {:reply, AgentsMapper.error(reason, nil), frame}
end
