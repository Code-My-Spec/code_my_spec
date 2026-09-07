defmodule CodeMySpecWeb.AgentStopRoundTripTest do
  @moduledoc """
  A stop travels to the machine and its answer comes back.

  The server owns the record and the machine owns the process, so stopping is a
  request to somebody else's computer — and rule 2 of story 961 says the stop is
  not done until the answer says the process is gone.

  This drives the wire rather than the intent. `Agents.stop_agent/2` calling a
  transport proves nothing on its own: the whole class of defect on this project
  is a handler with no producer, and the four already found were each covered by
  specs that built the payload themselves. So the channel is joined for real, the
  push is asserted as it leaves, and the reply is fed back through
  `handle_in/3` — the path a harness actually takes.
  """
  # Not async: the channel takes the project's advisory lock on join, which is
  # per-database and therefore genuinely shared even with sandboxed rows.
  use CodeMySpecTest.DataCase, async: false

  import Phoenix.ChannelTest
  import CodeMySpec.UsersFixtures

  alias CmsHarness.Project.ChannelClient
  alias CodeMySpecWeb.HarnessProjectChannel

  @endpoint CodeMySpecWeb.Endpoint

  @label "the copy under test"

  setup do
    scope = full_scope_fixture()
    topic = "harness_project:#{scope.active_project_id}"

    {:ok, _reply, socket} =
      CodeMySpecWeb.UserSocket
      |> socket("harness_socket:#{scope.active_working_copy_id}", %{scope: scope})
      |> subscribe_and_join(HarnessProjectChannel, topic, %{
        "label" => @label,
        "harness_id" => scope.active_working_copy_id
      })

    %{scope: scope, socket: socket}
  end

  defp ask_to_stop(socket, request) do
    caller = self()

    task =
      Task.async(fn ->
        send(caller, :asking)
        GenServer.call(socket.channel_pid, {:stop_agent, request}, 5_000)
      end)

    assert_receive :asking, 1_000
    task
  end

  test "the request reaches the machine carrying what it needs to signal", %{socket: socket} do
    task =
      ask_to_stop(socket, %{
        "agent_id" => "agent-1",
        "os_pid" => 4242,
        "os_boot_id" => "boot-abc",
        "grace_ms" => 100
      })

    assert_push "stop_agent", pushed, 2_000

    assert pushed["os_pid"] == 4242,
           "the machine cannot signal a group it was not told about"

    assert pushed["os_boot_id"] == "boot-abc",
           "without the boot the far side cannot tell our group from a recycled " <>
             "number, and the only safe thing to do with one of those is nothing"

    assert is_binary(pushed["ref"]),
           "no ref, so the answer has nothing to come back against"

    push(socket, "agent_stop_result", %{"ref" => pushed["ref"], "status" => "ok"})

    assert Task.await(task, 3_000) == :ok
  end

  test "a launch travels to the machine and its group id comes back", %{socket: socket} do
    caller = self()

    task =
      Task.async(fn ->
        send(caller, :asking)

        GenServer.call(
          socket.channel_pid,
          {:start_agent,
           %{
             "agent_id" => "agent-1",
             "engine" => "alloy",
             "config_dir" => "/tmp/cfg",
             "working_copy" => "/tmp/copy"
           }},
          5_000
        )
      end)

    assert_receive :asking, 1_000
    assert_push "start_agent", pushed, 2_000

    assert pushed["working_copy"] == "/tmp/copy",
           "the machine runs the agent in a checkout, so which one has to arrive"

    # Built by the encoder the machine actually uses, not written out here.
    # Hand-written, this asserted the decoder agreed with a literal in this file
    # — and both halves of this contract broke separately in one day without it
    # noticing.
    reply =
      Map.put(
        ChannelClient.encode_start_result({:ok, %{agent_id: "agent-99"}}),
        "ref",
        pushed["ref"]
      )

    push(socket, "agent_start_result", reply)

    assert Task.await(task, 3_000) == {:ok, %{agent_id: "agent-99"}},
           "the encoder and the decoder disagree about what a started agent is " <>
             "called. Nothing else compares them: every spex swaps in an " <>
             "in-process transport that encodes nothing."
  end

  test "a launch reporting a shape this server does not understand is not a start",
       %{socket: socket} do
    caller = self()

    task =
      Task.async(fn ->
        send(caller, :asking)
        GenServer.call(socket.channel_pid, {:start_agent, %{"engine" => "alloy"}}, 5_000)
      end)

    assert_receive :asking, 1_000
    assert_push "start_agent", pushed, 2_000

    # A success with nothing naming the agent. Recording it would leave a row
    # claiming to be running with no way to say which agent that is.
    push(socket, "agent_start_result", %{"ref" => pushed["ref"], "status" => "ok"})

    assert {:error, {:unexpected_start_result, _}} = Task.await(task, 3_000),
           "recording a group id with no boot beside it produces an agent that can " <>
             "never be judged: signalling it may reach a stranger, and reporting it " <>
             "stopped claims a stop that did not happen"
  end

  test "a machine that could not end the group does not report a stop", %{socket: socket} do
    task = ask_to_stop(socket, %{"agent_id" => "a", "os_pid" => 1, "os_boot_id" => "b"})

    assert_push "stop_agent", pushed, 2_000

    push(socket, "agent_stop_result", %{
      "ref" => pushed["ref"],
      "status" => "error",
      "reason" => "still_running"
    })

    assert Task.await(task, 3_000) == {:error, :still_running},
           "the far side said the process survived and the caller was told it " <>
             "stopped — which clears the group id and makes the survivor " <>
             "permanently unreachable"
  end

  test "an answer in a shape this server does not understand is not a stop", %{socket: socket} do
    task = ask_to_stop(socket, %{"agent_id" => "a", "os_pid" => 1, "os_boot_id" => "b"})

    assert_push "stop_agent", pushed, 2_000
    push(socket, "agent_stop_result", %{"ref" => pushed["ref"], "status" => "maybe?"})

    assert {:error, {:unexpected_stop_result, _}} = Task.await(task, 3_000)
  end

  test "a late answer against a ref nobody is waiting on does not take the channel down",
       %{socket: socket} do
    ref = push(socket, "agent_stop_result", %{"ref" => "never-asked", "status" => "ok"})
    assert_reply ref, :ok

    # Still serving. A channel that died here would disconnect every agent on
    # this copy over an answer that arrived after its caller gave up.
    ping = push(socket, "agent_stop_result", %{"ref" => "also-never", "status" => "ok"})
    assert_reply ping, :ok
  end
end
