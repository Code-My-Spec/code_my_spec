defmodule CodeMySpec.McpServers.Agents.Tools.ListAgents do
  @moduledoc """
  What is running on this project, and on which working copy.

  Nothing could answer this before: an agent was started by hand with
  `docker exec -d`, supervised by a bash loop, and the application found out a
  run had ended by noticing it stopped reporting.

  `reconcile: true` asks the device what it actually has rather than what we
  remember starting, and marks anything missing as stopped. The two disagreeing
  is the failure worth catching — an agent that outlived whatever started it
  keeps spending a subscription, and a row still claiming it runs is how nobody
  notices. It costs a round trip to the box, so it is opt-in.
  """

  use Anubis.Server.Component, type: :tool

  alias CodeMySpec.Agents
  alias CodeMySpec.McpServers.Agents.AgentsMapper
  alias CodeMySpec.McpServers.Validators

  schema do
    field :reconcile, :boolean,
      doc: "Ask the device what is actually running, instead of what was recorded"
  end

  @impl true
  def execute(params, frame) do
    with {:ok, scope} <- Validators.validate_local_scope(frame, params),
         {:ok, agents} <- fetch(scope, reconcile?(params)) do
      {:reply, AgentsMapper.listing(agents), frame}
    else
      {:error, reason} -> {:reply, AgentsMapper.error(reason, nil), frame}
    end
  end

  defp fetch(scope, true), do: Agents.reconcile_running(scope)
  defp fetch(scope, false), do: {:ok, Agents.list_running(scope)}

  defp reconcile?(params), do: params["reconcile"] == true or params[:reconcile] == true
end
