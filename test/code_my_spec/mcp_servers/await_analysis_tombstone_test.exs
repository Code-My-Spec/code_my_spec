defmodule CodeMySpec.McpServers.AwaitAnalysisTombstoneTest do
  @moduledoc """
  A removed tool that is still in someone's registry has to say so.

  `await_analysis` was deleted because it could not work — MCP caps a request at
  30s and a sweep runs 200-590s. Deleting it from the server did not delete it
  from agents: a client fetches the tool list once at session start, and a
  session here runs for hours, so the name outlives the tool by the length of
  the session and `ToolSearch` keeps handing back its schema.

  Calling it then answered `MCP error -32602: Invalid params`. Anubis puts
  "Tool not found" in `data.message` and leaves the generic string at the top
  level, which is the one the client shows — so the sentence that would have
  ended it was on the wire and unread. Against a schema with no params,
  "Invalid params" reads as *you built the call wrong*, and the reporter went
  looking for arguments that do not exist (`ba6904d6`).
  """

  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.UsersFixtures

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Analysis.Tools.AwaitAnalysis

  defp call(scope) do
    frame = %Frame{assigns: %{scope: scope}}

    assert {:reply, response, ^frame} = AwaitAnalysis.execute(%{}, frame)
    text(response)
  end

  defp text(%{content: content}) do
    Enum.map_join(content, "\n", fn %{"text" => t} -> t end)
  end

  test "it says the tool is gone and why" do
    message = call(full_scope_fixture())

    assert message =~ "was removed"
    assert message =~ "30 seconds"
  end

  test "it names the replacement endpoints" do
    message = call(full_scope_fixture())

    assert message =~ "/analysis/run"
    assert message =~ "/analysis/wait"
  end

  # The harness id filled in, because the failure this fixes is an agent that
  # cannot find the replacement — a URL it can paste beats one it must assemble.
  test "it fills in the harness id when the scope has one" do
    scope = full_scope_fixture()

    assert call(scope) =~ "/api/harnesses/#{scope.active_harness_id}"
  end

  # And says what to do about the stale list itself, so the next call is not the
  # same mistake.
  test "it explains why the tool was in the list at all" do
    message = call(full_scope_fixture())

    assert message =~ "fetched at session"
    assert message =~ "/mcp"
    assert message =~ "Nothing is wrong with your call"
  end
end
