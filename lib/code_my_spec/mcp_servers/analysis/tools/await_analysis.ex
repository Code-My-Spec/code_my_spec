defmodule CodeMySpec.McpServers.Analysis.Tools.AwaitAnalysis do
  @moduledoc """
  A tombstone for a tool that was removed, because the name outlives the tool.

  `await_analysis` could not work and was deleted: MCP caps a request at 30s and
  a sweep runs 200-590s, so the tool never returned for the case it existed to
  serve. `LocalServer` has said "No AwaitAnalysis here" ever since.

  Removing it from the server did not remove it from agents. A client fetches
  the tool list once, at session start, and a session here runs for hours — so
  a registry listing `await_analysis` outlives the tool by however long that
  session lasts, and `ToolSearch` hands back its schema on request. What the
  agent then gets from calling it is

      MCP error -32602: Invalid params

  because Anubis puts "Tool not found: await_analysis" in `data.message` while
  the top-level `message` stays the generic one, and the top-level is what the
  client shows. The useful sentence is on the wire and nobody reads it. "Invalid
  params" against a schema with no params reads as *the agent built the call
  wrong*, so the natural next move is to invent arguments — which is exactly
  where `ba6904d6` went.

  So this answers instead. It is not a working tool and its description says so
  first, which is what stops a *new* session picking it up: the cost of carrying
  a tombstone is that it appears in the list, and that is only worth paying if
  reading the entry is enough to not call it.

  Modelled on `sync_project`, which the report singles out as the right shape —
  a refusal that teaches rather than one that just fails.
  """

  use Anubis.Server.Component, type: :tool

  alias Anubis.Server.Response

  schema do
  end

  @impl true
  def execute(_params, frame) do
    {:reply, Response.tool() |> Response.text(explanation(frame)), frame}
  end

  # The harness id is filled in where it can be, because the whole failure this
  # fixes is an agent that cannot find the replacement. A URL it can paste beats
  # a URL it has to assemble.
  defp explanation(frame) do
    """
    `await_analysis` was removed and is not coming back. MCP caps a request at
    30 seconds; an analyzer sweep runs 200-590. The tool could not return for
    the one case it existed to serve, so waiting moved to HTTP, which has no
    such cap.

    Run a sweep:      POST #{base(frame)}/analysis/run
    Wait for one:     POST #{base(frame)}/analysis/wait

    Both are documented in AGENTS.md under "HTTP Endpoints (not MCP tools)".

    If this tool appeared in your tool list, that list was fetched at session
    start and the tool was already gone. Nothing is wrong with your call —
    reconnect with `/mcp` to refresh the list, or just use the endpoints above.
    """
    |> String.trim()
  end

  # Straight off the frame rather than through `validate_local_scope/1`. There
  # is nothing here to authorise — the reply is a URL shape and a paragraph of
  # prose — and a validator that refuses would drop the one detail that makes
  # the reply useful.
  defp base(frame) do
    case frame.assigns[:scope] do
      %{active_harness_id: id} when is_binary(id) ->
        "localhost:4004/api/harnesses/#{id}"

      _ ->
        "localhost:4004/api/harnesses/<harness_id>"
    end
  end
end
