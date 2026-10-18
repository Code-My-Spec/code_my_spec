defmodule CmsHarness.Agents.AnalysisWaitsUntilTheAgentIsDoneTest do
  @moduledoc """
  Engine turn boundaries and execution shutdown. Waiting payload ownership and
  FIFO delivery are exercised against the database mailbox in story 1051.
  These isolated harness tests use an explicit authority callback, not a queue.
  """
  use ExUnit.Case, async: true

  alias CmsHarness.Agents.Engine
  alias CmsHarnessTest.Machine

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    Machine.ensure_supervisor()
    %{root: tmp_dir}
  end

  # A plain assistant message with no tool calls, so a turn is one round trip
  # and ends as soon as the plug returns.
  # A streamed reply: the engine runs its turns through `Alloy.stream/3`, and
  # Alloy's Anthropic stream reads server-sent events.
  defp reply_body do
    [
      %{
        "type" => "message_start",
        "message" => %{
          "id" => "msg_1",
          "type" => "message",
          "role" => "assistant",
          "model" => "claude-opus-5",
          "content" => [],
          "usage" => %{"input_tokens" => 1, "output_tokens" => 0}
        }
      },
      %{
        "type" => "content_block_start",
        "index" => 0,
        "content_block" => %{"type" => "text", "text" => ""}
      },
      %{
        "type" => "content_block_delta",
        "index" => 0,
        "delta" => %{"type" => "text_delta", "text" => "ok"}
      },
      %{"type" => "content_block_stop", "index" => 0},
      %{
        "type" => "message_delta",
        "delta" => %{"stop_reason" => "end_turn"},
        "usage" => %{"output_tokens" => 1}
      },
      %{"type" => "message_stop"}
    ]
    |> Enum.map_join("", &"event: #{&1["type"]}\ndata: #{Jason.encode!(&1)}\n\n")
  end

  # The first request parks until released; later ones answer at once. The plug
  # runs inside the turn, so it hands the test its own pid — that is the only
  # handle on the process actually holding the turn open.
  defp gated_plug(test_pid) do
    counter = :counters.new(1, [])

    fn conn ->
      hold_first_turn(counter, test_pid, :counters.get(counter, 1))

      conn
      |> Plug.Conn.put_resp_content_type("text/event-stream")
      |> Plug.Conn.resp(200, reply_body())
    end
  end

  defp hold_first_turn(counter, test_pid, 0) do
    :counters.add(counter, 1, 1)
    send(test_pid, {:holding_turn, self()})

    receive do
      :release -> :ok
    after
      10_000 -> :ok
    end
  end

  defp hold_first_turn(_counter, _test_pid, _count), do: :ok

  defp start_agent(root, plug, events) do
    id = "turn-end-#{System.unique_integer([:positive])}"

    {:ok, _} =
      Machine.start_agent(id, root,
        provider: "anthropic",
        api_key: "unused",
        req_options: [plug: plug],
        on_event: fn _agent_id, envelope -> send(events, {:event, envelope}) end
      )

    on_exit(fn -> Machine.stop_agent(id) end)
    id
  end

  defp count_turn_ends(acc \\ 0) do
    receive do
      {:event, %{event: :turn_ended}} -> count_turn_ends(acc + 1)
      {:event, _other} -> count_turn_ends(acc)
    after
      800 -> acc
    end
  end

  test "both delivery modes require mailbox consumption before execution", %{root: root} do
    id = "denied-#{System.unique_integer([:positive])}"

    {:ok, _} =
      Machine.start_agent(id, root,
        provider: "anthropic",
        api_key: "unused",
        req_options: [plug: gated_plug(self())],
        on_consume: fn _, _, _ -> {:error, :withdrawn} end
      )

    on_exit(fn -> Machine.stop_agent(id) end)

    for await? <- [false, true] do
      assert {:error, :withdrawn} =
               CmsHarness.Agents.send_message(id, "withdrawn", "never run", 100, await: await?)
    end

    assert {:ok, %{busy?: false}} = CmsHarness.Agents.status(id)
    refute_receive {:holding_turn, _}
  end

  test "each executing turn reports a terminal boundary to the mailbox", %{root: root} do
    agent = start_agent(root, gated_plug(self()), self())

    assert {:ok, :started} = Machine.send_message(agent, "ref-a", "first")
    assert_receive {:holding_turn, plug_pid}, 5_000

    # Only the server mailbox may retain the second instruction.
    assert {:error, :busy} = Machine.send_message(agent, "ref-b", "second")
    assert {:ok, %{busy?: true}} = CmsHarness.Agents.status(agent)

    send(plug_pid, :release)

    assert count_turn_ends() == 1
  end

  test "busy engine refuses waiting payloads without retaining them", %{root: root} do
    agent = start_agent(root, gated_plug(self()), self())
    assert {:ok, :started} = Machine.send_message(agent, "running", "first")
    assert_receive {:holding_turn, plug_pid}, 5_000
    assert_receive {:event, %{event: :turn_started, ref: "running"}}

    for ref <- ["one", "two", "three"] do
      assert {:error, :busy} = CmsHarness.Agents.send_message(agent, ref, ref, 1)
    end

    assert {:ok, %{busy?: true}} = CmsHarness.Agents.status(agent)
    send(plug_pid, :release)
    assert_receive {:event, %{event: :turn_ended}}, 5_000
    refute_received {:event, %{event: :turn_started}}
  end

  test "a caller timeout leaves the running turn intact", %{root: root} do
    agent = start_agent(root, gated_plug(self()), self())
    [{engine, _}] = Registry.lookup(CmsHarness.Registry, {:agent, agent})

    caller =
      Task.async(fn ->
        catch_exit(GenServer.call(engine, {:send, "first", "first", 1, true}, 1))
      end)

    assert_receive {:holding_turn, execution}, 5_000
    assert {:timeout, _} = Task.await(caller)
    assert {:error, :busy} = Machine.send_message(agent, "waiting", "second")
    assert {:ok, %{busy?: true}} = CmsHarness.Agents.status(agent)
    assert Process.alive?(execution)
    refute_received {:event, %{event: :turn_started, ref: "waiting"}}

    send(execution, :release)
    assert_receive {:event, %{event: :turn_ended}}, 5_000
    assert {:ok, :started} = Machine.send_message(agent, "waiting", "queued instruction")
    assert_receive {:event, %{event: :turn_started, ref: "waiting"}}, 5_000
    assert_receive {:event, %{event: :turn_ended}}, 5_000
    refute_received {:event, %{event: :turn_failed}}
  end

  test "a crashed waiter cannot release queued work into the old execution", %{root: root} do
    agent = start_agent(root, gated_plug(self()), self())
    [{engine, _}] = Registry.lookup(CmsHarness.Registry, {:agent, agent})

    :sys.replace_state(engine, fn state ->
      %{state | provider_state: %{session_marker: "preserve-this-session"}}
    end)

    assert {:ok, :started} = Machine.send_message(agent, "running", "first")
    assert_receive {:holding_turn, execution}, 5_000
    assert {:error, :busy} = Machine.send_message(agent, "waiting", "second")
    state = :sys.get_state(engine)

    Process.exit(state.turn.task.pid, :kill)

    assert_receive {:event, %{event: :turn_ended}}, 5_000
    assert {:ok, :started} = Machine.send_message(agent, "waiting", "queued instruction")
    assert_receive {:event, %{event: :turn_started, ref: "waiting"}}, 5_000
    refute Process.alive?(execution)
    assert_receive {:event, %{event: :turn_failed}}, 5_000
    assert_receive {:event, %{event: :turn_ended}}, 5_000
    assert {:ok, %{busy?: false}} = CmsHarness.Agents.status(agent)
    assert {:ok, history} = Engine.history(agent)
    assert inspect(history) =~ "first"
    assert inspect(history) =~ "queued instruction"
    assert inspect(history) =~ "interrupted"
    assert :sys.get_state(engine).provider_state.session_marker == "preserve-this-session"
  end

  for mode <- [:direct, :supervised] do
    @tag ownership_mode: mode
    test "an aborted turn stops the #{mode} subprocess before queued delivery", %{
      root: root,
      ownership_mode: mode
    } do
      test_pid = self()
      counter = :counters.new(1, [])
      gated = gated_plug(test_pid)

      plug = fn conn ->
        start_first_subprocess(counter, test_pid, mode, :counters.get(counter, 1))

        gated.(conn)
      end

      agent = start_agent(root, plug, self())
      assert {:ok, :started} = Machine.send_message(agent, "running", "first")
      assert_receive {:owned_subprocess, os_pid}, 5_000

      on_exit(fn ->
        System.cmd("/bin/kill", ["-KILL", Integer.to_string(os_pid)], stderr_to_stdout: true)
      end)

      assert_receive {:holding_turn, _execution}, 5_000
      assert {:error, :busy} = Machine.send_message(agent, "waiting", "second")
      [{engine, _}] = Registry.lookup(CmsHarness.Registry, {:agent, agent})
      state = :sys.get_state(engine)

      Process.exit(state.turn.task.pid, :kill)

      assert_receive {:event, %{event: :turn_ended}}, 5_000
      assert {:ok, :started} = Machine.send_message(agent, "waiting", "queued instruction")
      assert_receive {:event, %{event: :turn_started, ref: "waiting"}}, 5_000

      {_output, status} =
        System.cmd("/bin/kill", ["-0", Integer.to_string(os_pid)], stderr_to_stdout: true)

      assert status != 0, "queued delivery began while the old subprocess was still alive"
      assert_receive {:event, %{event: :turn_ended}}, 5_000
    end
  end

  # A turned-off Claude Code agent's `claude -p` kept editing its copy for ten
  # minutes: stopping an agent closed its ports, which does not end the
  # programs behind them, and its loop ran on in a task nothing linked.
  for mode <- [:direct, :supervised] do
    @tag ownership_mode: mode
    test "stopping an agent mid-turn stops its #{mode} subprocess", %{
      root: root,
      ownership_mode: mode
    } do
      test_pid = self()
      counter = :counters.new(1, [])
      gated = gated_plug(test_pid)

      plug = fn conn ->
        start_first_subprocess(counter, test_pid, mode, :counters.get(counter, 1))
        gated.(conn)
      end

      agent = start_agent(root, plug, self())
      assert {:ok, :started} = Machine.send_message(agent, "running", "first")
      assert_receive {:owned_subprocess, os_pid}, 5_000

      on_exit(fn ->
        System.cmd("/bin/kill", ["-KILL", Integer.to_string(os_pid)], stderr_to_stdout: true)
      end)

      assert_receive {:holding_turn, _execution}, 5_000

      :ok = Machine.stop_agent(agent)

      {_output, status} =
        System.cmd("/bin/kill", ["-0", Integer.to_string(os_pid)], stderr_to_stdout: true)

      assert status != 0, "the agent stopped and its turn's subprocess kept running"
    end
  end

  defp start_first_subprocess(counter, test_pid, mode, 0) do
    :counters.add(counter, 1, 1)
    start_owned_subprocess(test_pid, mode)
  end

  defp start_first_subprocess(_counter, _test_pid, _mode, _count), do: :ok

  defp start_owned_subprocess(test_pid, :direct) do
    port =
      Port.open({:spawn_executable, System.find_executable("sleep")}, [
        :binary,
        :exit_status,
        {:args, ["30"]}
      ])

    {:os_pid, os_pid} = Port.info(port, :os_pid)
    send(test_pid, {:owned_subprocess, os_pid})
  end

  defp start_owned_subprocess(test_pid, :supervised) do
    Task.Supervisor.async_nolink(Alloy.TaskSupervisor, fn ->
      start_owned_subprocess(test_pid, :direct)

      receive do
        :release -> :ok
      end
    end)
  end

  # The other half: an agent that finishes with nothing waiting is done, and
  # that is exactly when the analyzers should run.
  test "a settle with an empty queue announces", %{root: root} do
    plug = fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("text/event-stream")
      |> Plug.Conn.resp(200, reply_body())
    end

    agent = start_agent(root, plug, self())

    Machine.send_message(agent, "ref-only", "just the one")

    assert count_turn_ends() == 1,
           "an agent that finished with nothing queued is done, and nothing ran the analyzers"
  end
end
