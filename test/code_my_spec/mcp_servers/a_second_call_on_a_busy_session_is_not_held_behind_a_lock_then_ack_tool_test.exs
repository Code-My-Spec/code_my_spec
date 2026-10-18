defmodule CodeMySpec.McpServers.BusySessionFixture.SlowAckTool do
  @moduledoc """
  Test-only tool mirroring the lock-then-ack shape 4f7929e4/f2977826 already
  gave real tools (provision_account_server, adopt_repository, stop_app,
  restart_app, ensure_app_running): acks the MCP call at once and defers the
  real, slow work to a detached task the Anubis session never waits on.
  """
  use Anubis.Server.Component, type: :tool

  alias Anubis.Server.Response

  def name, do: "slow_ack_tool"

  @impl true
  def description, do: "test-only: acks at once, defers real work to a detached task"

  schema do
    %{}
  end

  @impl true
  def execute(_params, frame) do
    coordinator = Process.whereis(:busy_session_test_coordinator)
    send(coordinator, {:slow_tool_dispatched, self()})

    receive do
      :proceed -> :ok
    end

    {:ok, _pid} =
      Task.Supervisor.start_child(:busy_session_test_task_sup, fn ->
        receive do
          :release -> :ok
        end
      end)

    {:reply, Response.tool() |> Response.text("started"), frame}
  end
end

defmodule CodeMySpec.McpServers.BusySessionFixture.FastTool do
  @moduledoc "A trivial tool with no work to defer -- the one queued behind SlowAckTool."
  use Anubis.Server.Component, type: :tool

  alias Anubis.Server.Response

  def name, do: "fast_tool"

  @impl true
  def description, do: "test-only: replies immediately, nothing to defer"

  schema do
    %{}
  end

  @impl true
  def execute(_params, frame) do
    {:reply, Response.tool() |> Response.text("fast done"), frame}
  end
end

defmodule CodeMySpec.McpServers.BusySessionFixture.Server do
  @moduledoc "Throwaway Anubis server exposing only the two fixture tools above."
  use Anubis.Server,
    name: "busy-session-fixture",
    version: "1.0.0",
    capabilities: [:tools]

  component(CodeMySpec.McpServers.BusySessionFixture.SlowAckTool)
  component(CodeMySpec.McpServers.BusySessionFixture.FastTool)
end

defmodule CodeMySpec.McpServers.ASecondCallOnABusySessionIsNotHeldBehindALockThenAckToolTest do
  @moduledoc """
  Issue 35e5eb59: one Anubis session is shared by every subagent of a
  team-lead run (a subagent inherits its parent's MCP transport --
  `LocalServer`'s own moduledoc: "A subagent shares its parent's
  transport"). `Anubis.Server.Session.Scheduler` enforces at most one
  request executing per session: a concurrent second caller is appended to
  `request_queue` and gets no reply until the first is dispatched, run, and
  replied to -- entirely inside the pinned `anubis_mcp` dependency
  (mix.exs: `~> 1.14`), with no hook exposed to change that routing
  decision from our own code.

  What IS our own code, and what this issue's own fix is: every tool a busy
  session is likely to call in parallel (4f7929e4, f2977826) now acks the
  call at once and defers its real work to a detached task outside the
  session's own bookkeeping -- so the SESSION's single in-flight slot, per
  request, is held only as long as the ack itself takes, not as long as the
  real work does. This proves that shape against the real, unmodified
  `Anubis.Server.Session`/`Scheduler`: a second call genuinely queued behind
  a first one gets its answer well inside its own timeout, because the
  first's ack returns at once -- never because the real work (which this
  test deliberately never lets finish) completed.

  No sleeps: every ordering point is a message a test-registered coordinator
  process receives or releases, not a wait-and-hope duration.
  """
  use ExUnit.Case, async: false

  alias CodeMySpec.McpServers.BusySessionFixture.Server

  setup do
    Process.register(self(), :busy_session_test_coordinator)
    {:ok, _sup} = Task.Supervisor.start_link(name: :busy_session_test_task_sup)

    unique = System.unique_integer([:positive])

    {:ok, session} =
      Anubis.Server.Session.start_link(
        session_id: "busy-session-test-#{unique}",
        server_module: Server,
        name: :"busy_session_test_session_#{unique}",
        transport: [
          layer: Anubis.Server.Transport.StreamableHTTP,
          name: :"busy_session_test_transport_#{unique}"
        ],
        task_supervisor: :busy_session_test_task_sup,
        pre_initialized: true
      )

    # No on_exit teardown: `start_link/1` already links the session to this
    # test process, so it goes down when the test does.
    %{session: session}
  end

  test "a queued call answers once the first tool's ack returns, not once its real work finishes",
       %{session: session} do
    call1 =
      Task.async(fn ->
        GenServer.call(session, {:mcp_request, tools_call(1, "slow_ack_tool"), %{}}, 5_000)
      end)

    assert_receive {:slow_tool_dispatched, exec_pid}, 1_000

    call2 =
      Task.async(fn ->
        GenServer.call(session, {:mcp_request, tools_call(2, "fast_tool"), %{}}, 2_000)
      end)

    assert Task.yield(call2, 50) == nil,
           "fast_tool should still be queued behind slow_ack_tool's un-acked call"

    send(exec_pid, :proceed)

    {:ok, call1} = Task.yield(call1, 1_000)
    {:ok, call2} = Task.yield(call2, 1_000)

    assert tool_text(call1) == "started"
    assert tool_text(call2) == "fast done"
  end

  defp tools_call(id, tool_name) do
    %{
      "jsonrpc" => "2.0",
      "id" => id,
      "method" => "tools/call",
      "params" => %{"name" => tool_name, "arguments" => %{}}
    }
  end

  defp tool_text({:ok, json}) when is_binary(json) do
    json
    |> Jason.decode!()
    |> get_in(["result", "content"])
    |> List.first()
    |> Map.fetch!("text")
  end
end
