defmodule CodeMySpecLocalWeb.HarnessChannelTest do
  @moduledoc """
  The data-plane harness channel: an `agent_message` from a lane is relayed UP
  toward the server (asserted via the relay PubSub seam, no server needed), and
  the manager's `dispatch` is routed DOWN to the target lane's topic.

  Also what is *running*. `agents_running` had a handler on the server and no
  producer anywhere, so the working-copies page showed every checkout idle no
  matter how many agents were on it. These assert against the same relay seam,
  which is where the absence would have shown up.
  """

  use CodeMySpecTest.DataCase, async: true

  import Phoenix.ChannelTest
  import CodeMySpec.UsersFixtures

  alias CodeMySpec.AgentHarness
  alias CodeMySpecLocalWeb.LaneReporter

  @endpoint CodeMySpecLocalWeb.Endpoint

  @external_id "pi:/tmp/harness-test-proj"

  setup do
    scope = full_scope_fixture()

    # In production `SocketSupervisor` starts one of these per account. Started
    # here because the reporter is what these tests are about — without it the
    # relay seam is silent, which is exactly the state that shipped.
    start_supervised!({LaneReporter, scope: scope})

    {:ok, _reply, channel} =
      CodeMySpecLocalWeb.HarnessSocket
      |> socket("harness_socket:#{@external_id}", %{
        scope: scope,
        account_id: scope.active_account_id,
        external_id: @external_id
      })
      |> subscribe_and_join(
        CodeMySpecLocalWeb.HarnessChannel,
        "harness:session:#{@external_id}",
        %{"role" => "coding"}
      )

    # `:after_join` runs asynchronously, so the join returning does not mean
    # `Presence.track/4` has run. Draining the mailbox establishes that much.
    :sys.get_state(channel.channel_pid)

    # And this establishes the part that actually matters. `track/4` returning
    # is not `Presence.list/1` reflecting it — Phoenix.Tracker replicates the
    # join through its own loop, and every test in this file reads a report that
    # needs `coding` to be in that list.
    #
    # `await_lane/2` was added for exactly this and applied only to the two
    # tests that join a *second* lane, leaving the lane they all share
    # unsynchronised. Under a loaded suite it lost that lane often enough to
    # fail most full runs, as whichever test read first — so it looked
    # intermittent while being entirely deterministic about the thing it was
    # waiting on.
    :ok = await_lane(scope, "coding")

    %{scope: scope, channel: channel}
  end

  test "agent_message is relayed up toward the server", %{scope: scope, channel: channel} do
    :ok = AgentHarness.subscribe_relay(scope.active_account_id)

    push(channel, "agent_message", %{
      "role" => "coding",
      "kind" => "assistant",
      "text" => "wrote the schema"
    })

    assert_receive {:relay_up, "agent_message", payload}
    assert payload["text"] == "wrote the schema"
    assert payload["role"] == "coding"
    assert payload["external_id"] == @external_id
    assert payload["project_id"] == scope.active_project_id
  end

  test "a joined lane is reported to the server as running", %{scope: scope} do
    :ok = AgentHarness.subscribe_relay(scope.active_account_id)

    # The proxy asking on reconnect. Also the cheapest way to observe the set
    # without racing the join that already happened in setup.
    AgentHarness.request_report(scope.active_account_id)

    # Two hops, not one: the request broadcasts to `LaneReporter`, which reads
    # Presence and broadcasts again. `assert_receive`'s 100ms default bounds the
    # machine rather than the code — this failed only in the full suite and
    # never in 20 isolated runs. A longer bound on genuinely async delivery is
    # not a sleep waiting for something to become true.
    assert_receive {:relay_up, "agents_running", %{"agents" => agents}}, 2_000

    assert [%{"working_copy" => "/tmp/harness-test-proj", "role" => "coding", "engine" => "alloy"}] =
             agents
  end

  test "a second lane on one copy is reported beside the first, not instead of it",
       %{scope: scope} do
    {:ok, _reply, qa} =
      CodeMySpecLocalWeb.HarnessSocket
      |> socket("harness_socket:#{@external_id}-qa", %{
        scope: scope,
        account_id: scope.active_account_id,
        external_id: @external_id
      })
      |> subscribe_and_join(
        CodeMySpecLocalWeb.HarnessChannel,
        "harness:session:#{@external_id}",
        %{"role" => "qa"}
      )

    :sys.get_state(qa.channel_pid)
    :ok = await_lane(scope, "qa")

    :ok = AgentHarness.subscribe_relay(scope.active_account_id)
    AgentHarness.request_report(scope.active_account_id)

    agents = await_report(["coding", "qa"])

    assert Enum.sort(Enum.map(agents, & &1["role"])) == ["coding", "qa"],
           "one checkout runs one or more lanes. Reporting a single agent per " <>
             "copy is what made the server's reconcile overwrite one lane with " <>
             "the next, so the page showed one row flickering between them."

    assert Enum.all?(agents, &(&1["working_copy"] == "/tmp/harness-test-proj")),
           "both lanes are on the same checkout and have to say so, or they land " <>
             "on two working copies that do not exist"
  end

  test "a lane declares its engine and provider, and they reach the report", %{scope: scope} do
    {:ok, _reply, declared} =
      CodeMySpecLocalWeb.HarnessSocket
      |> socket("harness_socket:#{@external_id}-declared", %{
        scope: scope,
        account_id: scope.active_account_id,
        external_id: @external_id
      })
      |> subscribe_and_join(
        CodeMySpecLocalWeb.HarnessChannel,
        "harness:session:#{@external_id}",
        %{"role" => "product", "engine" => "alloy", "provider" => "anthropic"}
      )

    :sys.get_state(declared.channel_pid)
    :ok = await_lane(scope, "product")

    :ok = AgentHarness.subscribe_relay(scope.active_account_id)
    AgentHarness.request_report(scope.active_account_id)

    agents = await_report(["coding", "product"])
    declared = Enum.find(agents, &(&1["role"] == "product"))

    assert declared["provider"] == "anthropic",
           "the lane is the only thing that knows which subscription it spends, " <>
             "so a report that drops what it declared cannot answer the question " <>
             "the page exists for"

    assert declared["engine"] == "alloy"
  end

  test "a lane that declares nothing is still reported, as a Pi lane on an unknown provider",
       %{scope: scope} do
    :ok = AgentHarness.subscribe_relay(scope.active_account_id)
    AgentHarness.request_report(scope.active_account_id)

    agents = await_report(["coding"])
    coding = Enum.find(agents, &(&1["role"] == "coding"))

    assert coding["engine"] == "alloy" and coding["provider"] == "unknown",
           "identity used to belong to the session, so a lane written before " <>
             "that changed declares only its role. It still has to appear — " <>
             "dropping it would make the page quietly wrong rather than vague."
  end

  test "dispatch is routed to the target lane's topic", %{channel: channel} do
    :ok = AgentHarness.subscribe_lane(@external_id, "qa")

    push(channel, "dispatch", %{"role" => "qa", "prompt" => "verify the story"})

    assert_receive {:to_lane, "user_message", payload}
    assert payload["text"] == "verify the story"
  end

  # Block until the lanes topic has actually recorded this lane.
  #
  # `:sys.get_state/1` on the channel proves `Presence.track/4` returned;
  # `Presence.list/1` reads what Phoenix.Tracker has replicated, which is a
  # separate step. The gap is invisible on an idle machine and wide enough to
  # lose a report on a busy one — this passed alone 15 times and failed twice in
  # the full suite.
  #
  # Bumping `assert_receive`'s timeout treated that as slowness. It is not: it
  # is an unsynchronised read, and a bigger number only makes it rarer. The
  # tracker broadcasts `presence_diff` once it has recorded the join, so this
  # waits on the real signal.
  defp await_lane(scope, role) do
    topic = AgentHarness.lanes_topic(scope.active_account_id)
    Phoenix.PubSub.subscribe(CodeMySpec.PubSub, topic)
    await_lane(topic, role, 40)
  end

  defp await_lane(topic, role, 0), do: flunk("#{role} never appeared on #{topic}")

  defp await_lane(topic, role, attempts) do
    topic
    |> tracked?(role)
    |> keep_waiting_for_lane(topic, role, attempts)
  end

  defp tracked?(topic, role) do
    topic
    |> CodeMySpecLocalWeb.Presence.list()
    |> Enum.flat_map(fn {_key, %{metas: metas}} -> metas end)
    |> Enum.any?(&(&1.role == role))
  end

  defp keep_waiting_for_lane(true, _topic, _role, _attempts), do: :ok

  defp keep_waiting_for_lane(false, topic, role, attempts) do
    receive do
      %Phoenix.Socket.Broadcast{event: "presence_diff"} -> :ok
    after
      50 -> :ok
    end

    await_lane(topic, role, attempts - 1)
  end

  # The report that answers the question, rather than whichever arrives first.
  #
  # `LaneReporter` reports on every `presence_diff` as well as on request, so
  # the second lane's own join produces one. The test subscribes to the relay
  # after joining, so a report composed a moment before both lanes were up can
  # still be in flight and be the first message matched — a true statement about
  # an earlier moment, and not the one being asked about.
  #
  # Still bounded, and still catches the defect this test is for: a server that
  # overwrites one lane with the next never produces a report carrying both, so
  # this times out rather than passing on a stale message.
  defp await_report(roles), do: await_report(roles, 2_000)

  defp await_report(roles, remaining) when remaining <= 0 do
    flunk("no report carrying #{inspect(roles)} arrived")
  end

  defp await_report(roles, remaining) do
    started = System.monotonic_time(:millisecond)

    receive do
      {:relay_up, "agents_running", %{"agents" => agents}} ->
        matched? = Enum.sort(Enum.map(agents, & &1["role"])) == Enum.sort(roles)
        take_report(matched?, agents, roles, remaining, started)
    after
      remaining -> flunk("no report carrying #{inspect(roles)} arrived")
    end
  end

  # The report we were waiting for, or one to wait past. Clauses rather than a
  # branch: the credo rule bans imperative `if` in a test file, and the decision
  # here is a boolean that reads better in a head than in a conditional.
  defp take_report(true, agents, _roles, _remaining, _started), do: agents

  defp take_report(false, _agents, roles, remaining, started) do
    elapsed = System.monotonic_time(:millisecond) - started
    await_report(roles, remaining - max(elapsed, 1))
  end
end
