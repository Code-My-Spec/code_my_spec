defmodule CodeMySpec.McpServers.Agents.Tools.StopAgent do
  @moduledoc """
  Stop one running agent.

  One, and only one. A stop that reaps the whole tree, or kills by name and
  catches a sibling, is indistinguishable from this one at the call site and is
  worse than having no stop at all — the agents left alone are the point.
  """

  use Anubis.Server.Component, type: :tool

  alias CodeMySpec.Agents
  alias CodeMySpec.McpServers.Agents.AgentsMapper
  alias CodeMySpec.McpServers.Validators
  alias CodeMySpec.Utils.MapAccess

  schema do
    field :agent_id, :string, required: true, doc: "Id of the agent to stop"
  end

  @impl true
  def execute(params, frame) do
    with {:ok, scope} <- Validators.validate_local_scope(frame, params),
         {:ok, agent} <- Agents.stop_agent(scope, agent_id(params)) do
      {:reply, AgentsMapper.stopped(agent), frame}
    else
      {:error, reason} -> {:reply, AgentsMapper.error(reason, nil), frame}
    end
  end

  defp agent_id(params), do: MapAccess.get(params, :agent_id)
end
