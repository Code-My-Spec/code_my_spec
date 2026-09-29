defmodule CodeMySpec.McpServers.MainAgent.ContinuousMapper do
  @moduledoc "Reports continuous intent separately from process lifecycle."

  alias Anubis.Server.Response

  @spec set(map(), boolean(), atom()) :: Response.t()
  def set(agent, true, :enabled_and_turn_requested) do
    Response.tool()
    |> Response.text("""
    Continuous enabled: #{agent.id}

    It had eligible work, so a turn has just been requested — the agent chooses
    which requirement to claim. No process was started or restarted; this is
    the existing agent taking another turn.
    """)
  end

  def set(agent, true, :enabled_without_work) do
    Response.tool()
    |> Response.text("""
    Continuous enabled: #{agent.id}

    Nothing was requested, because there is nothing for it to do right now: no
    eligible work for its role on its working copy, or it is mid-turn or
    holding an undispositioned task. No process was started or restarted, and
    it will be offered a turn when that changes.

    `list_agent_work` says which of those it is.
    """)
  end

  # The older shape, kept so a caller that still answers `:enabled` is not
  # refused outright.
  def set(agent, true, _enabled) do
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
    No agent or conversation with that id exists here. `list_agent_work` has
    the agent ids.

    Ids print truncated on most surfaces; this takes the whole one.
    """)
  end

  def error(reason),
    do: Response.tool() |> Response.error("Could not do that: #{inspect(reason)}")
end
