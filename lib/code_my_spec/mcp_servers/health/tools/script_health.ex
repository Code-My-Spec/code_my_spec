defmodule CodeMySpec.McpServers.Health.Tools.ScriptHealth do
  @moduledoc """
  Answers `ok` from inside `run_script`. The scriptable half of `Health`.

  Same two jobs: it proves a Lua function can be reached through `run_script`
  on this machine, and the seeded call gives the agent's transcript a worked
  example of the nested form — the shape agents get wrong far more often than
  the direct one.
  """

  use Anubis.Server.Component, type: :tool

  alias Anubis.Server.Response

  schema do
  end

  @impl true
  def execute(_params, frame) do
    {:reply, Response.tool() |> Response.text("ok"), frame}
  end
end
