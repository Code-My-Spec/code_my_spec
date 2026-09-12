defmodule CodeMySpec.CodeMode.AStaleToolListIsNamedTest do
  @moduledoc """
  "Call it directly" is advice that can be wrong, and the refusal says when.

  An MCP connection negotiates its tool list once, when it opens, and never
  revisits it. A session that outlives a server change keeps working against the
  old surface with nothing reporting the skew — the same shape the stop hook
  already detects and names for the harness/server channel, except nothing
  detects it here.

  Measured 2026-09-12 (`9b08283d`): `promote` had just been registered on the
  server. An agent was told by `start_task` to call it, tried `promote()` inside
  `run_script` and got a refusal saying "you already have it directly", tried it
  directly and got `Unknown tool`. `tools/list` over the proxy showed 19 tools
  including `promote`; the session's own list carried 17. A `/mcp` reconnect
  surfaced it immediately.

  So the refusal asserted the remedy confidently and the remedy did not work,
  which is worse than the bare absence it had replaced: an agent that believes
  it holds the tool reaches for spellings rather than for its connection.
  """
  use ExUnit.Case, async: true

  alias CodeMySpec.CodeMode
  alias CodeMySpec.CodeMode.Catalog

  defp catalog do
    Catalog.from(
      [%{name: "list_stories", description: "List stories"}],
      fn _tool -> fn _args -> {:ok, "ok"} end end,
      nil
    )
  end

  defp run(script), do: CodeMode.eval(catalog(), script, [])

  test "an excluded tool still says why it is excluded" do
    result = run(~s|return promote({})|)

    assert result.error.message =~ "cannot be called from a script"
    assert result.error.message =~ "Call it directly as a tool"
  end

  test "and names the one case where calling it directly does not work" do
    result = run(~s|return promote({})|)

    assert result.error.message =~ "Unknown tool",
           "the agent hits this exact string next; the refusal should have predicted it"

    assert result.error.message =~ "/mcp",
           "naming the remedy is the whole point — an agent that is told it has a " <>
             "tool it does not have retries spellings rather than reconnecting"
  end

  # Every excluded tool, not just promote: the list is negotiated once for all
  # of them, so any tool registered after a session opened has this failure.
  test "every excluded tool carries the note" do
    for name <- Catalog.excluded() do
      result = run("return #{name}({})")

      assert result.error.message =~ "/mcp",
             "#{name}'s refusal does not mention the stale-list case"
    end
  end
end
