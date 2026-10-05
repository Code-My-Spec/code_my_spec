defmodule CmsHarness.Agents.AnalysisWaitsUntilTheAgentIsDoneTest do
  @moduledoc """
  A turn end is announced when the agent is done, not between turns of one run.

  `announce_turn_end/1` is what fires the analyzers and produces the stop
  decision — the internal equivalent of Claude Code's Stop hook. It fired on
  every turn end, on the reasoning that "`Analysis` supersedes a duplicate
  rather than running it twice, so the cost of saying so early is a row".

  In continuous mode a turn ends every 15-20 seconds: the loop delivers a
  message, the agent acts, it settles, the decision sends another. Each settle
  enqueued a full sweep while a spex run takes ~176s. Measured on one working
  copy: 84 superseded against 26 completed, and the decision an agent got was
  built from whatever last completed — several turns behind the tree it was
  looking at.

  John: "it should only run the analyzer when the agent is fully done, not like
  between tool calls and stuff."

  The signal was already in the struct. `drain/1` reads `queue` one line below
  `announce_turn_end/1` to decide whether another turn starts immediately.

  Driven through real engine turns with a provider that parks the first request
  until this test releases it, so "a message arrived while the agent was
  mid-turn" is a fact rather than a race. No sleeps: the plug says when it has
  the turn, and the test says when to let go.
  """
  use ExUnit.Case, async: false

  alias CmsHarness.Agents.Engine
  alias CmsHarness.Agents.Liveness
  alias CmsHarnessTest.Machine

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    Machine.ensure_supervisor()
    previous = Application.get_env(:code_my_spec, :agent_queue_receipts_dir)
    Application.put_env(:code_my_spec, :agent_queue_receipts_dir, Path.join(tmp_dir, "receipts"))

    on_exit(fn -> restore_receipts_dir(previous) end)

    %{root: tmp_dir}
  end

  # A plain assistant message with no tool calls, so a turn is one round trip
  # and ends as soon as the plug returns.
  defp reply_body do
    Jason.encode!(%{
      "id" => "msg_1",
      "type" => "message",
      "role" => "assistant",
      "model" => "claude-opus-5",
      "content" => [%{"type" => "text", "text" => "ok"}],
      "stop_reason" => "end_turn",
      "usage" => %{"input_tokens" => 1, "output_tokens" => 1}
    })
  end

  # The first request parks until released; later ones answer at once. The plug
  # runs inside the turn, so it hands the test its own pid — that is the only
  # handle on the process actually holding the turn open.
  defp gated_plug(test_pid) do
    counter = :counters.new(1, [])

    fn conn ->
      hold_first_turn(counter, test_pid, :counters.get(counter, 1))

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
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

  test "a queued message lost in a crash is not reported as delivered", %{root: root} do
    :ok = Liveness.subscribe()
    agent = start_agent(root, gated_plug(self()), self())
    assert_receive {:agent_liveness, :up, ^agent, _, nil}, 2_000
    assert {:ok, :started} = Machine.send_message(agent, "running", "first")
    assert_receive {:holding_turn, _execution}, 5_000
    assert {:ok, :queued} = Machine.send_message(agent, "waiting", "take this back")
    assert {:ok, pid} = Engine.State.whereis(agent)

    Process.exit(pid, :kill)
    assert_receive {:agent_liveness, :down, ^agent, _, :killed}, 2_000
    assert_receive {:agent_liveness, :up, ^agent, _, nil}, 5_000

    refute_received {:event, %{event: :message_delivered, ref: "waiting"}}
    assert :ok = Machine.withdraw(agent, "waiting")
    assert {:error, :already_delivered} = Machine.withdraw(agent, "running")
    assert {:ok, %{busy?: false, queued: 0}} = Engine.status(agent)
  end

  test "an unconsumed message remains withdrawable after its Keeper is replaced", %{root: root} do
    plug = gated_plug(self())
    agent = start_agent(root, plug, self())
    assert {:ok, :started} = Machine.send_message(agent, "running", "first")
    assert_receive {:holding_turn, _execution}, 5_000
    assert {:ok, :queued} = Machine.send_message(agent, "waiting", "take this back")
    assert :ok = Machine.stop_agent(agent)

    assert {:ok, _} =
             Machine.start_agent(agent, root,
               provider: "anthropic",
               api_key: "unused",
               req_options: [plug: plug]
             )

    assert :ok = Machine.withdraw(agent, "waiting")
    assert {:error, :already_delivered} = Machine.withdraw(agent, "running")
    assert {:ok, %{busy?: false, queued: 0}} = Engine.status(agent)
  end

  test "a consumed queued message stays non-withdrawable after Keeper replacement", %{root: root} do
    plug = gated_plug(self())
    agent = start_agent(root, plug, self())
    assert {:ok, :started} = Machine.send_message(agent, "running", "first")
    assert_receive {:holding_turn, execution}, 5_000
    assert {:ok, :queued} = Machine.send_message(agent, "waiting", "second")

    send(execution, :release)
    assert_receive {:event, %{event: :message_delivered, ref: "waiting"}}, 5_000
    assert_receive {:event, %{event: :turn_ended}}, 5_000
    assert {:ok, %{busy?: false, queued: 0}} = Engine.status(agent)
    assert :ok = Machine.stop_agent(agent)

    assert {:ok, _} =
             Machine.start_agent(agent, root,
               provider: "anthropic",
               api_key: "unused",
               req_options: [plug: plug]
             )

    assert {:error, :already_delivered} = Machine.withdraw(agent, "waiting")
  end

  test "the settle that has work queued behind it stays quiet", %{root: root} do
    agent = start_agent(root, gated_plug(self()), self())

    assert {:ok, :started} = Machine.send_message(agent, "ref-a", "first")
    assert_receive {:holding_turn, plug_pid}, 5_000

    # Queued rather than started, said by the engine itself: it runs one turn at
    # a time and the turn it is on is the one parked in the plug above. This is
    # the state the old code announced from.
    assert {:ok, :queued} = Machine.send_message(agent, "ref-b", "second")
    assert {:ok, %{busy?: true, queued: 1}} = Engine.status(agent)

    send(plug_pid, :release)

    assert count_turn_ends() == 1, """
    Two turns ran and both announced. The first settled with the second already
    on the queue — the agent was between two turns of one run, not done — and
    announcing there is what enqueued a sweep every 15 seconds while one was
    still going.
    """
  end

  test "three instructions wait for the running turn and are delivered in order", %{root: root} do
    agent = start_agent(root, gated_plug(self()), self())
    assert {:ok, :started} = Machine.send_message(agent, "running", "first")
    assert_receive {:holding_turn, plug_pid}, 5_000
    assert_receive {:event, %{event: :message_delivered, ref: "running"}}

    assert {:ok, :queued} = Engine.send_message(agent, "one", "instruction one", 1)
    assert {:ok, :queued} = Engine.send_message(agent, "two", "instruction two", 1)
    assert {:ok, :queued} = Engine.send_message(agent, "three", "instruction three", 1)
    assert {:ok, %{busy?: true, queued: 3}} = Engine.status(agent)
    refute_received {:event, %{event: :message_delivered}}

    send(plug_pid, :release)
    assert_receive {:event, %{event: :message_delivered, ref: "one"}}, 5_000
    assert_receive {:event, %{event: :message_delivered, ref: "two"}}, 5_000
    assert_receive {:event, %{event: :message_delivered, ref: "three"}}, 5_000
    assert_receive {:event, %{event: :turn_ended}}, 5_000
    assert {:ok, %{busy?: false, queued: 0}} = Engine.status(agent)
    refute_received {:event, %{event: :turn_failed}}
  end

  test "a caller timeout leaves the running turn and its queue intact", %{root: root} do
    agent = start_agent(root, gated_plug(self()), self())
    [{engine, _}] = Registry.lookup(CmsHarness.Registry, {:agent, agent})

    caller =
      Task.async(fn ->
        catch_exit(GenServer.call(engine, {:chat, "first", 1}, 1))
      end)

    assert_receive {:holding_turn, execution}, 5_000
    assert {:timeout, _} = Task.await(caller)
    assert {:ok, :queued} = Machine.send_message(agent, "waiting", "second")
    assert {:ok, %{busy?: true, queued: 1}} = Engine.status(agent)
    assert Process.alive?(execution)
    refute_received {:event, %{event: :message_delivered, ref: "waiting"}}

    send(execution, :release)
    assert_receive {:event, %{event: :message_delivered, ref: "waiting"}}, 5_000
    assert_receive {:event, %{event: :turn_ended}}, 5_000
    refute_received {:event, %{event: :turn_failed}}
  end

  test "the finite ceiling stops execution before delivering queued work", %{root: root} do
    agent = start_agent(root, gated_plug(self()), self())
    [{engine, _}] = Registry.lookup(CmsHarness.Registry, {:agent, agent})
    original = :sys.get_state(engine).alloy

    :sys.replace_state(original, fn state ->
      %{state | provider_state: %{session_marker: "preserve-this-session"}}
    end)

    assert {:ok, :started} = Machine.send_message(agent, "running", "original instruction")
    assert_receive {:holding_turn, execution}, 5_000
    assert {:ok, :queued} = Machine.send_message(agent, "waiting", "queued instruction")
    [{engine, _}] = Registry.lookup(CmsHarness.Registry, {:agent, agent})
    state = :sys.get_state(engine)
    remaining = Process.read_timer(state.turn.timer)
    assert is_integer(remaining) and remaining > 0 and remaining <= :timer.minutes(30)
    assert state.alloy == execution
    monitor = Process.monitor(execution)

    # Deliver the real timer's message without making the test wait 30 minutes.
    send(engine, {:turn_ceiling, state.turn.task.ref})
    assert_receive {:event, %{event: :message_delivered, ref: "waiting"}}, 5_000
    refute Process.alive?(execution)
    assert_receive {:DOWN, ^monitor, :process, ^execution, :killed}
    assert_receive {:event, %{event: :turn_failed}}, 5_000
    assert_receive {:event, %{event: :turn_ended}}, 5_000
    assert {:ok, %{busy?: false, queued: 0}} = Engine.status(agent)
    assert {:ok, history} = Engine.history(agent)
    assert inspect(history) =~ "original instruction"
    assert inspect(history) =~ "queued instruction"
    assert inspect(history) =~ "interrupted"
    replacement = :sys.get_state(engine).alloy
    assert :sys.get_state(replacement).provider_state.session_marker == "preserve-this-session"

    send(engine, {:turn_ceiling, state.turn.task.ref})
    assert {:ok, %{busy?: false, queued: 0}} = Engine.status(agent)
    assert Engine.running?(agent)
    refute_received {:event, %{event: :turn_failed}}
  end

  test "a crashed waiter cannot release queued work into the old execution", %{root: root} do
    agent = start_agent(root, gated_plug(self()), self())
    assert {:ok, :started} = Machine.send_message(agent, "running", "first")
    assert_receive {:holding_turn, execution}, 5_000
    assert {:ok, :queued} = Machine.send_message(agent, "waiting", "second")
    [{engine, _}] = Registry.lookup(CmsHarness.Registry, {:agent, agent})
    state = :sys.get_state(engine)

    Process.exit(state.turn.task.pid, :kill)

    assert_receive {:event, %{event: :message_delivered, ref: "waiting"}}, 5_000
    refute Process.alive?(execution)
    assert_receive {:event, %{event: :turn_failed}}, 5_000
    assert_receive {:event, %{event: :turn_ended}}, 5_000
    assert {:ok, %{busy?: false, queued: 0}} = Engine.status(agent)
  end

  for mode <- [:direct, :supervised] do
    @tag ownership_mode: mode
    test "ceiling stops the #{mode} subprocess before queued delivery", %{
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
      assert {:ok, :queued} = Machine.send_message(agent, "waiting", "second")
      [{engine, _}] = Registry.lookup(CmsHarness.Registry, {:agent, agent})
      state = :sys.get_state(engine)

      send(engine, {:turn_ceiling, state.turn.task.ref})

      assert_receive {:event, %{event: :message_delivered, ref: "waiting"}}, 5_000

      {_output, status} =
        System.cmd("/bin/kill", ["-0", Integer.to_string(os_pid)], stderr_to_stdout: true)

      assert status != 0, "queued delivery began while the old subprocess was still alive"
      assert_receive {:event, %{event: :turn_ended}}, 5_000
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

  defp restore_receipts_dir(nil),
    do: Application.delete_env(:code_my_spec, :agent_queue_receipts_dir)

  defp restore_receipts_dir(dir),
    do: Application.put_env(:code_my_spec, :agent_queue_receipts_dir, dir)

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
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, reply_body())
    end

    agent = start_agent(root, plug, self())

    Machine.send_message(agent, "ref-only", "just the one")

    assert count_turn_ends() == 1,
           "an agent that finished with nothing queued is done, and nothing ran the analyzers"
  end
end
