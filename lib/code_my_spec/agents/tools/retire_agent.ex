defmodule CodeMySpec.Agents.Tools.RetireAgent do
  @moduledoc false
  @behaviour CodeMySpec.Tools.Tool

  alias CodeMySpec.Agents
  alias CodeMySpec.Agents.Tools.Responses, as: AgentsMapper
  alias CodeMySpec.Utils.MapAccess

  @impl true
  def name, do: "retire_agent"

  @impl true
  def description do
    """
    Retire an agent: end it for good and free its seat.

    Not the same as `turn_off_agent` (39af5611). Off keeps the agent's seat and
    can be undone with `turn_on_agent`; retired cannot be undone. A retired agent
    never runs or receives anything again, and `start_agent` may put a new agent
    in its seat. Its conversation stays for history.
    """
  end

  @impl true
  def params do
    %{
      reason: {:meta, :string, [description: "Optional. Why it is being retired."]},
      agent_id: {:required, {:meta, :string, [description: "Id of the agent to retire"]}}
    }
  end

  @impl true
  def call(params, context) do
    case CodeMySpec.Tools.project_scope(context) do
      {:ok, scope} ->
        scope
        |> Agents.retire_agent(MapAccess.get(params, :agent_id),
          by: Agents.actor(scope, context[:agent_id]),
          reason: MapAccess.get(params, :reason)
        )
        |> reply(context)

      {:error, reason} ->
        reply({:error, reason}, context)
    end
  end

  defp reply({:ok, agent}, _context), do: AgentsMapper.retired(agent)

  defp reply({:ok, agent, {:unreachable, machine}}, _context),
    do: AgentsMapper.retired(agent, machine)

  defp reply({:error, reason}, _context), do: AgentsMapper.error(reason, nil)
end
