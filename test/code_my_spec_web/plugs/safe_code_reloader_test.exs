defmodule CodeMySpecWeb.Plugs.SafeCodeReloaderTest do
  @moduledoc """
  d8b4226e: Phoenix.CodeReloader.Server briefly unavailable used to crash
  the whole request with an unhandled exit, which Plug.Debugger (debug_errors:
  true, dev/demo) turned into a 500 page dumping the request's own headers --
  Authorization included. Reproduced here by injecting a :reloader that
  exits the same way GenServer.call does against a process that is not
  alive, rather than touching the real, globally shared
  Phoenix.CodeReloader.Server.
  """
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias CodeMySpecWeb.Plugs.SafeCodeReloader

  defp conn do
    Plug.Test.conn(:get, "/") |> Plug.Conn.put_private(:phoenix_endpoint, CodeMySpecWeb.Endpoint)
  end

  test "a successful reload check passes the conn through unchanged" do
    opts = SafeCodeReloader.init(reloader: fn _endpoint, _opts -> :ok end)
    original = conn()

    assert SafeCodeReloader.call(original, opts) == original
  end

  test "the server being unavailable does not crash the request" do
    opts =
      SafeCodeReloader.init(
        reloader: fn _endpoint, _opts ->
          exit(
            {:noproc,
             {GenServer, :call, [Phoenix.CodeReloader.Server, {:reload!, nil, []}, :infinity]}}
          )
        end
      )

    original = conn()

    log =
      capture_log(fn ->
        assert SafeCodeReloader.call(original, opts) == original
      end)

    assert log =~ "Phoenix.CodeReloader failed",
           "the crash should be logged rather than silently swallowed:\n#{log}"
  end

  test "any kind of crash from the reloader is caught, not only an exit" do
    opts = SafeCodeReloader.init(reloader: fn _endpoint, _opts -> raise "boom" end)
    original = conn()

    log =
      capture_log(fn ->
        assert SafeCodeReloader.call(original, opts) == original
      end)

    assert log =~ "Phoenix.CodeReloader failed"
  end

  test "an MCP call gets retry-later during a failed reload, then succeeds after recovery" do
    {:ok, attempts} = Agent.start_link(fn -> 0 end)

    opts =
      SafeCodeReloader.init(
        reloader: fn _endpoint, _opts ->
          Agent.get_and_update(attempts, fn
            0 -> {{:error, "lib/foo.ex:42: a real compile error"}, 1}
            n -> {:ok, n + 1}
          end)
        end
      )

    request =
      Plug.Test.conn(:post, "/mcp/harness")
      |> Plug.Conn.put_private(:phoenix_endpoint, CodeMySpecWeb.Endpoint)

    log =
      capture_log(fn ->
        response = SafeCodeReloader.call(request, opts)
        assert response.status == 503
        assert response.halted
        assert Plug.Conn.get_resp_header(response, "retry-after") == ["1"]
        assert response.resp_body == "Code reload in progress; retry shortly."
        refute response.resp_body =~ "CompileError"
      end)

    assert log =~ "lib/foo.ex:42: a real compile error"
    assert SafeCodeReloader.call(request, opts) == request
  end

  test "a genuine compile error still halts with its own 500, unchanged" do
    opts =
      SafeCodeReloader.init(
        reloader: fn _endpoint, _opts -> {:error, "lib/foo.ex:42: a real compile error"} end
      )

    log =
      capture_log(fn ->
        result = SafeCodeReloader.call(conn(), opts)
        assert result.status == 500
        assert result.halted
        assert result.resp_body =~ "a real compile error"
      end)

    assert log =~ "lib/foo.ex:42: a real compile error"
  end
end
