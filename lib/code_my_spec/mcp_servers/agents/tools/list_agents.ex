defmodule CodeMySpec.McpServers.Agents.Tools.ListAgents do
  @moduledoc """
  What is running on this project, and on which working copy.

  Nothing could answer this before: an agent was started by hand with
  `docker exec -d`, supervised by a bash loop, and the application found out a
  run had ended by noticing it stopped reporting.

  This is what the server was told. The device's own answer arrives over the
  harness channel as `agents_running`, which is a projection of Presence on the
  lane topics — a lane is joined for exactly as long as it is alive. So a row
  here that the harness has stopped reporting is already marked stopped by the
  time anybody asks.
  """

  use Anubis.Server.Component, type: :tool

  alias CodeMySpec.Agents
  alias CodeMySpec.McpServers.Agents.AgentsMapper
  alias CodeMySpec.McpServers.Validators

  schema do
  end

  @impl true
  def execute(params, frame) do
    case Validators.validate_local_scope(frame, params) do
      {:ok, scope} -> {:reply, AgentsMapper.listing(listed(scope)), frame}
      {:error, reason} -> {:reply, AgentsMapper.error(reason, nil), frame}
    end
  end

  # Every agent on duty, whether or not its process is up, and any still
  # running though turned off. An agent asked for that never came up is listed,
  # so it can be found and cancelled (criterion 975); listing only present ones
  # (v2.0.372) hid exactly those.
  defp listed(scope),
    do: Enum.uniq_by(Agents.list_on_duty(scope) ++ Agents.list_running(scope), & &1.id)
end
