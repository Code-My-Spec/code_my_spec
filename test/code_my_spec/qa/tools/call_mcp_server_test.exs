defmodule CodeMySpec.Qa.Tools.CallMcpServerTest.PingTool do
  @moduledoc false
  use Anubis.Server.Component, type: :tool

  alias Anubis.Server.Response

  schema do
  end

  @impl true
  def execute(_params, frame) do
    {:reply, Response.tool() |> Response.text("pong"), frame}
  end
end

defmodule CodeMySpec.Qa.Tools.CallMcpServerTest.PingServer do
  @moduledoc false
  use Anubis.Server,
    name: "call-mcp-server-test",
    version: "1.0.0",
    capabilities: [:tools]

  component(CodeMySpec.Qa.Tools.CallMcpServerTest.PingTool)
end

defmodule CodeMySpec.Qa.Tools.CallMcpServerTest.Refuses do
  @moduledoc false
  @behaviour Plug

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts), do: Plug.Conn.send_resp(conn, 401, "")
end

defmodule CodeMySpec.Qa.Tools.CallMcpServerTest do
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

  alias CodeMySpec.Qa.Tools.CallMcpServer
  alias CodeMySpec.ToolLibrary
  alias Anubis.Server.{Frame, Response}
  alias CodeMySpec.Qa.Tools.CallMcpServerTest.PingServer

  setup do
    scope = full_scope_fixture()
    %{scope: scope, frame: %Frame{assigns: %{current_scope: scope}}}
  end

  defp response_text({_status, text}), do: text

  describe "a caller who named no server" do
    test "is told what to pass and where ours are", %{frame: frame} do
      # Past argument validation, as the original drove `execute/2`: the
      # tool's own refusal for a missing url is what is under test.
      reply = CallMcpServer.call(%{}, %{scope: frame.assigns.current_scope})

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
      reply =
        ToolLibrary.run(
          "call_mcp_server",
          %{url: "http://127.0.0.1:1", path: "/mcp", timeout: 2_000},
          Map.put(frame.assigns, :scope, frame.assigns[:current_scope])
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

  # 3942db94: /mcp/harness answered 401 to a caller with no bearer token, and
  # this read as `{:session_died, {:noproc, …}}`.
  describe "a server that refuses the caller" do
    @describetag :capture_log

    setup do
      bandit = start_supervised!({Bandit, plug: __MODULE__.Refuses, port: 0, startup_log: false})
      {:ok, {_address, port}} = ThousandIsland.listener_info(bandit)
      %{url: "http://127.0.0.1:#{port}"}
    end

    test "says it was refused, with the status", %{frame: frame, url: url} do
      {:error, text} =
        ToolLibrary.run(
          "call_mcp_server",
          %{url: url, path: "/mcp/harness", timeout: 5_000},
          Map.put(frame.assigns, :scope, frame.assigns[:current_scope])
        )

      [_could_not_open, headline | _rest] = String.split(text, "\n\n")
      assert headline =~ "Refused: HTTP 401"
      assert headline =~ "Authorization: Bearer"
    end
  end

  describe "a server that is actually running" do
    @describetag :capture_log

    setup do
      start_supervised!({PingServer, transport: {:streamable_http, start: true}})

      bandit =
        start_supervised!(
          {Bandit,
           plug: {Anubis.Server.Transport.StreamableHTTP.Plug, server: PingServer},
           port: 0,
           startup_log: false}
        )

      {:ok, {_address, port}} = ThousandIsland.listener_info(bandit)

      %{url: "http://127.0.0.1:#{port}"}
    end

    test "lists the tools it offers", %{frame: frame, url: url} do
      reply =
        ToolLibrary.run(
          "call_mcp_server",
          %{url: url, path: "/mcp", timeout: 5_000},
          Map.put(frame.assigns, :scope, frame.assigns[:current_scope])
        )

      text = response_text(reply)

      assert text =~ "ping_tool",
             "a server that answered was not read as one offering a tool named ping_tool:\n#{text}"

      # Whose tools these are: an agent read a list like this as its own catalog.
      assert text =~ "#{url}/mcp offers this caller 1 tool(s)"
      assert text =~ "not yours"
    end

    test "calls the tool it offers", %{frame: frame, url: url} do
      reply =
        ToolLibrary.run(
          "call_mcp_server",
          %{url: url, path: "/mcp", tool: "ping_tool", timeout: 5_000},
          Map.put(frame.assigns, :scope, frame.assigns[:current_scope])
        )

      text = response_text(reply)

      assert text =~ "pong",
             "calling the one tool this server offers did not return its answer:\n#{text}"
    end
  end
end
