defmodule CodeMySpec.McpServers.MainAgent.ContinuousMapper do
  @moduledoc "Reports continuous intent separately from process lifecycle."

  alias Anubis.Server.Response

  @spec set(map(), boolean(), atom()) :: Response.t()
  def set(agent, true, :enabled) do
    Response.tool()
    |> Response.text("""
    Continuous enabled: #{agent.id}

    The existing agent may take another turn when idle and eligible for work.
    No process was started or restarted. Its current task must be dispositioned
    before it can choose another task.
    """)
  end

  def set(agent, false, _disposition) do
    Response.tool()
    |> Response.text("""
    Continuous disabled: #{agent.id}

    No new automatic work turn will be requested. The current turn and queued
    conversation content are not interrupted, and the durable agent remains.
    """)
  end

  @spec error(term()) :: Response.t()
  def error(:not_found) do
    Response.tool()
    |> Response.error("""
    No agent on this project has that id. `list_agent_work` has the ones that
    are yours.

    Ids print truncated on most surfaces; this takes the whole one.
    """)
  end

  def error(reason),
    do: Response.tool() |> Response.error("Could not do that: #{inspect(reason)}")
end
