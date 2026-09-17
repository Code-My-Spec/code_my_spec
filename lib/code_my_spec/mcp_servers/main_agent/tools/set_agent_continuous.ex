defmodule CodeMySpec.McpServers.MainAgent.Tools.SetAgentContinuous do
  @moduledoc """
  Put one of your agents in the loop, or let it leave.

  Starting an agent and putting it to work are different acts, and only the
  first had a tool. An agent that is started but not continuous takes one turn
  and stops, so a fleet could be started and still do nothing — which is what
  "my agents are not running" turns out to mean most times it is said.

  Answers what actually happened, because switching on is not one outcome. The
  flag alone marks an agent willing and leaves it where it was: an agent is a
  supervised process that acts when messaged, and nothing polls. So this rings
  its bell too, and says whether the bell reached something.
  """

  # `Agents.set_agent_continuous/3` already existed and the cockpit already
  # called it — a person could toggle this from a conversation and the main
  # agent could not, which is the gap `d3660c2f` records. The only tool that
  # reached it was `set_working_copy_loop`, which is the wrong grain twice over:
  # it is per working copy, so it starts every role on that copy including ones
  # nobody asked for, and it is on the product role rather than main.
  #
  # Per agent, because the fleet is heterogeneous. One copy commonly carries a
  # QA agent that should keep working and a coding agent that should not.

  use Anubis.Server.Component, type: :tool

  alias CodeMySpec.Agents
  alias CodeMySpec.McpServers.MainAgent.ContinuousMapper
  alias CodeMySpec.McpServers.Validators
  alias CodeMySpec.Utils.MapAccess

  schema do
    field :agent_id, :string, required: true, doc: "From `list_agent_work`."

    field :continuous, :boolean,
      required: true,
      doc: "True puts it in the loop and wakes it. False lets it stop after its current turn."
  end

  @impl true
  def execute(params, frame) do
    with {:ok, scope} <- Validators.validate_local_scope(frame, params),
         {:ok, agent, disposition} <-
           Agents.set_agent_continuous(scope, agent_id(params), continuous?(params)) do
      {:reply, ContinuousMapper.set(agent, continuous?(params), disposition), frame}
    else
      {:error, reason} -> {:reply, ContinuousMapper.error(reason), frame}
    end
  end

  defp agent_id(params), do: MapAccess.get(params, :agent_id)
  defp continuous?(params), do: MapAccess.get(params, :continuous)
end
