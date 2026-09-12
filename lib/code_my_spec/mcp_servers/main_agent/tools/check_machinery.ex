defmodule CodeMySpec.McpServers.MainAgent.Tools.CheckMachinery do
  @moduledoc """
  Whether the things your agents depend on are working: the harness, the tool
  surface, the preview, the analyzers and the machine itself.

  Ask it when an agent misbehaves, before restarting anything. A fault every
  agent shares is one fault underneath them and restarting them will not reach
  it; a fault one agent has while its neighbours work is that agent's.

  Healthy is reported as well as broken, so you can rule the machinery out.
  """

  # Separate from `list_agent_work`, which reports per agent. This reports what
  # sits under every agent, and the difference is the whole point: folded into
  # the per-agent view, one shared fault would be repeated against each agent —
  # which is the reading that cost four hours when a stale MCP client told three
  # agents their tools did not exist.

  use Anubis.Server.Component, type: :tool

  alias CodeMySpec.MainAgent
  alias CodeMySpec.McpServers.MainAgent.MachineryMapper
  alias CodeMySpec.McpServers.Validators

  schema do
  end

  @impl true
  def execute(_params, frame) do
    case Validators.validate_local_scope(frame) do
      {:ok, scope} -> {:reply, MachineryMapper.report(MainAgent.check_machinery(scope)), frame}
      {:error, reason} -> {:reply, MachineryMapper.error(reason), frame}
    end
  end
end
