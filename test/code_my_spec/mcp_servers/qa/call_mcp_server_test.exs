defmodule CodeMySpec.McpServers.Qa.CallMcpServerTest do
  @moduledoc """
  The instrument QA tests a tool surface with.

  What is worth covering without a live MCP server on the other end is the part
  that gets read by a person: a caller who gave no URL, and a caller whose URL
  answered nothing. Both are refusals, and a refusal that does not say which of
  several things went wrong is how `50eac6ab` cost a whole session — the
  reporter could not tell "not mounted" from "not permitted".
  """

  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.UsersFixtures

  alias Anubis.Server.{Frame, Response}
  alias CodeMySpec.McpServers.Qa.Tools.CallMcpServer

  setup do
    scope = full_scope_fixture()
    %{scope: scope, frame: %Frame{assigns: %{current_scope: scope}}}
  end

  defp response_text(response) do
    response
    |> Response.to_protocol()
    |> Map.get("content")
    |> Enum.map_join("\n", &Map.get(&1, "text", ""))
  end

  describe "a caller who named no server" do
    test "is told what to pass and where ours are", %{frame: frame} do
      {:reply, reply, _frame} = CallMcpServer.execute(%{}, frame)

      text = response_text(reply)

      assert text =~ "needs a `url`",
             "the refusal does not say what is missing:\n#{text}"

      assert text =~ "/api/harnesses/",
             """
             The refusal names no actual server, so an agent that has never
             called this has to go and find one. Both of ours are one line each
             and the harness proxy is the one a QA session wants.

             #{text}
             """
    end
  end

  describe "a server that answers nothing" do
    @tag :capture_log
    test "says so, and says what else it could have been", %{frame: frame} do
      # Nothing listens here. Port 1 is privileged and unbindable, so this is a
      # refusal rather than a race against whatever happens to be running.
      {:reply, reply, _frame} =
        CallMcpServer.execute(
          %{url: "http://127.0.0.1:1", path: "/mcp", timeout: 2_000},
          frame
        )

      text = response_text(reply)

      assert text =~ "Could not open an MCP session",
             "the failure does not say what failed:\n#{text}"

      assert text =~ "http://127.0.0.1:1/mcp",
             "the failure does not name what it tried to reach:\n#{text}"

      assert text =~ "nothing listening at all",
             """
             The failure does not distinguish the three things that arrive here
             — nothing listening, a path that is not an MCP mount, and a mount
             that refused these headers.

             That distinction is the point of the tool. `50eac6ab` is a QA
             session that could not tell "this tool is not mounted" from "my
             role may not call it", and reported the second when the first was
             true.

             #{text}
             """
    end
  end
end
