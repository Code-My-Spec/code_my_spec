defmodule CodeMySpec.Agents.Tools.RestartAgent do
  @moduledoc false
  @behaviour CodeMySpec.Tools.Tool

  alias CodeMySpec.Agents.Main, as: MainAgent
  alias CodeMySpec.Agents.Tools.RestartResponses, as: RestartMapper
  alias CodeMySpec.Utils.MapAccess

  @impl true
  def name, do: "restart_agent"

  @impl true
  def description do
    """
    Restart one of your agents, saying why.

    The reason is not a label: it is checked against what has already been tried.
    A restart for a reason that has been tried and did not work is refused and
    raised as an issue instead, because restarting something restarting does not
    fix is a loop with a cost.

    Restarts one agent. Not the harness — that would kill in-flight work on every
    checkout on the machine, other projects included.
    """
  end

  @impl true
  def params do
    %{
      reason:
        {:required,
         {:meta, :string,
          [
            description:
              "What you are restarting it to fix. Checked against what was already tried."
          ]}},
      agent_id: {:required, {:meta, :string, [description: "From `list_agent_work`."]}}
    }
  end

  @impl true
  def call(params, context) do
    with {:ok, scope} <- CodeMySpec.Tools.project_scope(context),
         {:ok, agent} <- MainAgent.restart_agent(scope, agent_id(params), reason(params)) do
      RestartMapper.restarted(agent, reason(params))
    else
      {:error, reason} -> RestartMapper.error(reason)
    end
  end

  defp agent_id(params), do: MapAccess.get(params, :agent_id)
  defp reason(params), do: MapAccess.get(params, :reason)
end
