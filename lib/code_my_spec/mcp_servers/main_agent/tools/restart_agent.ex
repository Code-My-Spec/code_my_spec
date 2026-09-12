defmodule CodeMySpec.McpServers.MainAgent.Tools.RestartAgent do
  @moduledoc """
  Restart one of your agents, saying why.

  The reason is not a label: it is checked against what has already been tried.
  A restart for a reason that has been tried and did not work is refused and
  raised as an issue instead, because restarting something restarting does not
  fix is a loop with a cost.

  Restarts one agent. Not the harness — that would kill in-flight work on every
  checkout on the machine, other projects included.
  """

  # Same row and same transcript, via `Agents.restart_agent/2`. Starting afresh
  # inserts a new row and a conversation keys on the agent id, so the
  # replacement would come back with no memory of what it was doing — which is
  # the outcome a restart exists to avoid.

  use Anubis.Server.Component, type: :tool

  alias CodeMySpec.MainAgent
  alias CodeMySpec.McpServers.MainAgent.RestartMapper
  alias CodeMySpec.McpServers.Validators
  alias CodeMySpec.Utils.MapAccess

  schema do
    field :agent_id, :string, required: true, doc: "From `list_agent_work`."

    field :reason, :string,
      required: true,
      doc: "What you are restarting it to fix. Checked against what was already tried."
  end

  @impl true
  def execute(params, frame) do
    with {:ok, scope} <- Validators.validate_local_scope(frame, params),
         {:ok, agent} <- MainAgent.restart_agent(scope, agent_id(params), reason(params)) do
      {:reply, RestartMapper.restarted(agent, reason(params)), frame}
    else
      {:error, reason} -> {:reply, RestartMapper.error(reason), frame}
    end
  end

  defp agent_id(params), do: MapAccess.get(params, :agent_id)
  defp reason(params), do: MapAccess.get(params, :reason)
end
