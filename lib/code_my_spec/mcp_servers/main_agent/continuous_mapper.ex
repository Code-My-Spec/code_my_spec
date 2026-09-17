defmodule CodeMySpec.McpServers.MainAgent.ContinuousMapper do
  @moduledoc """
  What putting an agent in the loop actually did.

  Four outcomes rather than "ok", because switching on is a flag *and* a nudge
  and they can disagree. An agent whose row says `running` may have nothing
  behind it — that column is written on a clean start and a clean stop, so a
  harness restart leaves it claiming life indefinitely. Reporting success for
  the flag while the nudge reached nobody is how a fleet comes to look busy and
  do nothing.
  """

  alias Anubis.Server.Response

  @spec set(map(), boolean(), atom()) :: Response.t()
  def set(agent, true, :woke) do
    Response.tool()
    |> Response.text("""
    In the loop: #{agent.id}

    It was there and has been nudged, so it takes a turn now rather than waiting
    for something to happen to it. It keeps going until its role runs out of
    work or somebody stops it.
    """)
  end

  def set(agent, true, :restarted) do
    Response.tool()
    |> Response.text("""
    In the loop, after a restart: #{agent.id}

    Nothing was behind the row — it said `running` and no process answered — so
    it was started fresh in place rather than nudged. Same row, same transcript,
    so it comes back knowing what it was doing.

    Worth noticing rather than passing over: a row claiming life with nothing
    serving it means something took the process down without a clean stop.
    """)
  end

  def set(agent, true, :restart_failed) do
    Response.tool()
    |> Response.error("""
    Not in the loop: #{agent.id}

    The flag is set, but nothing was there to nudge and starting it again failed
    too. The error is in the log rather than swallowed.

    This agent will not take a turn. Do not treat it as running — check whether
    its working copy is still on a connected harness, which is the usual cause.
    """)
  end

  def set(agent, false, _disposition) do
    Response.tool()
    |> Response.text("""
    Out of the loop: #{agent.id}

    It finishes the turn it is in and then stops. Nothing is sent either way —
    letting an agent stop is the absence of a message, not a message.
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
