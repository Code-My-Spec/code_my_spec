defmodule CodeMySpec.McpServers.Health.Tools.Health do
  @moduledoc """
  Answers `ok`. Takes nothing, reads nothing, changes nothing.

  Two jobs, neither of them work.

  It proves the tool surface is live before an agent is handed anything. The
  harness calls it at launch, and if it answers, direct tool calling works on
  this machine — so an agent later reporting that its tools are unreachable is
  reporting something we already know to be false, rather than something to go
  and investigate. That distinction cost most of a night on 2026-09-21.

  And the call and its result are seeded into the agent's history, so the
  transcript opens with a worked example of the wire format in the agent's own
  voice. `ProviderBrief` describes that format in prose; this demonstrates it.

  Paired with `Health.Tools.ScriptHealth`, which does the same for the nested
  form a Lua function needs.
  """

  use Anubis.Server.Component, type: :tool

  schema do
  end

  @impl true
  def execute(_params, frame) do
    {:reply, Anubis.Server.Response.text(Anubis.Server.Response.tool(), "ok"), frame}
  end
end
