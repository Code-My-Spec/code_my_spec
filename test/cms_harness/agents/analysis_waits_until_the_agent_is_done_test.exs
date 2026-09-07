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
  alias CmsHarnessTest.Machine

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    Machine.ensure_supervisor()
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
      if :counters.get(counter, 1) == 0 do
        :counters.add(counter, 1, 1)
        send(test_pid, {:holding_turn, self()})

        receive do
          :release -> :ok
        after
          10_000 -> :ok
        end
      end

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, reply_body())
    end
  end

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
