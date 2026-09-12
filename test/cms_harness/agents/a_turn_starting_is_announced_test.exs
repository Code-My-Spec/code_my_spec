defmodule CmsHarness.Agents.ATurnStartingIsAnnouncedTest do
  @moduledoc """
  A turn beginning is announced, not only a turn ending.

  `Agents.record_turn_event/4` stamps `turn_started_at` from a `"turn_started"`
  event, `MainAgent.WorkRepository.list_agent_work/1` reads it, and
  `AgentWorkMapper.in_flight/1` renders it. All three were written for story
  1054's criteria 3297 and 3279 — the server-side comment names them — and the
  only thing that ever produced the event was a spex fixture calling the channel
  directly. So the field was reachable in test and unreachable in production,
  and the spex were green the whole time.

  QA found it by measurement rather than by reading (`b48aa9e8`): a real coding
  agent was given a long generation and polled about ninety times across two
  runs, while `message_agent`'s own busy tracking agreed it was mid-turn. Every
  sample answered "in flight: nothing — no turn is open".

  What that costs is criterion 3279's whole point. A long reasoning turn is
  supposed to be distinguishable from a stalled agent, so nobody restarts it
  mid-flight and throws away the turn and the model spend. With no signal, a
  stall cannot be ruled out — and neither can work in flight be confirmed.

  Driven through a real engine turn with a provider that parks the request, so
  "the agent is mid-turn" is a fact rather than a race.
  """
  use ExUnit.Case, async: false

  alias CmsHarness.Project.ChannelClient
  alias CmsHarnessTest.Machine

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    Machine.ensure_supervisor()
    %{root: tmp_dir}
  end

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

  # Parks inside the turn and hands the test the pid holding it, so the
  # assertions below run while the turn is genuinely open.
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
    id = "turn-start-#{System.unique_integer([:positive])}"

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

  test "the engine announces a turn start before the turn finishes", %{root: root} do
    agent = start_agent(root, gated_plug(self()), self())

    assert {:ok, :started} = Machine.send_message(agent, "ref-a", "think about this")

    # While the provider is parked: the start must already have been announced,
    # or nothing can tell this agent from an idle one.
    assert_receive {:holding_turn, plug_pid}, 5_000
    assert_receive {:event, %{event: :turn_started}}, 5_000

    send(plug_pid, :release)
    assert_receive {:event, %{event: :turn_ended}}, 5_000
  end

  # The end is deliberately quiet while more work is queued — the loop has not
  # finished. A start is true every time one happens, so a run of queued turns
  # reads as continuously busy rather than as busy once.
  test "a queued turn announces its own start", %{root: root} do
    agent = start_agent(root, gated_plug(self()), self())

    assert {:ok, :started} = Machine.send_message(agent, "ref-a", "first")
    assert_receive {:holding_turn, plug_pid}, 5_000
    assert {:ok, :queued} = Machine.send_message(agent, "ref-b", "second")

    assert_receive {:event, %{event: :turn_started}}, 5_000
    send(plug_pid, :release)

    assert_receive {:event, %{event: :turn_started}},
                   5_000,
                   "the queued turn opened without saying so, so an agent working " <>
                     "through a queue reads as idle for all but the first turn"
  end

  # The wire shape is what `Agents.record_turn_event/4` matches on, and it
  # matches the literal string. An envelope that encoded to anything else would
  # leave this whole path built and still unreachable, which is the defect.
  test "it encodes to the kind the server stamps turn_started_at from" do
    assert %{"kind" => "turn_started"} =
             ChannelClient.encode_turn_event(%{event: :turn_started, turn: 1})
  end

  test "the engine is the producer, not a test fixture" do
    source = File.read!("lib/cms_harness/agents/engine.ex")

    assert source =~ "announce_turn_start",
           "the only producer was a spex fixture calling the channel directly, which is " <>
             "why the spex passed and production never populated the field"
  end
end
