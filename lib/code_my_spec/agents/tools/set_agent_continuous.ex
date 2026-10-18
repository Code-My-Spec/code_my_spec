defmodule CodeMySpec.Agents.Tools.SetAgentContinuous do
  @moduledoc false
  @behaviour CodeMySpec.Tools.Tool

  alias CodeMySpec.Agents
  alias CodeMySpec.Agents.Tools.ContinuousResponses, as: ContinuousMapper
  alias CodeMySpec.Utils.MapAccess

  @impl true
  def name, do: "set_agent_continuous"

  @impl true
  def description do
    """
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
  end

  @impl true
  def params do
    %{
      agent_id: {:required, {:meta, :string, [description: "From `list_agent_work`."]}},
      continuous:
        {:required,
         {:meta, :boolean,
          [
            description:
              "True puts it in the loop and wakes it. False lets it stop after its current turn."
          ]}}
    }
  end

  @impl true
  def call(params, context) do
    with {:ok, scope} <- CodeMySpec.Tools.project_scope(context),
         {:ok, agent, disposition} <-
           Agents.set_agent_continuous(scope, agent_id(params), continuous?(params)) do
      ContinuousMapper.set(agent, continuous?(params), disposition)
    else
      {:error, reason} -> ContinuousMapper.error(reason)
    end
  end

  defp agent_id(params), do: MapAccess.get(params, :agent_id)
  defp continuous?(params), do: MapAccess.get(params, :continuous)
end
