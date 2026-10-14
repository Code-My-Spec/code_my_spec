defmodule CodeMySpecTest.AgentTransportRouterTest do
  @moduledoc """
  A later test's route must not catch an earlier test's straggler.

  The transport used to keep one global owner — the pid of whichever test
  last called `listen/0` — so a fire-and-forget dispatch Task still in
  flight from an earlier test's project landed in whatever process had
  since registered, and a loose `assert_receive` pattern could not tell the
  difference from its own delivery
  (`a_run_a_restart_killed_is_run_again_test.exs:156`, story 1091's
  promotion batch). Keying ownership by project id instead is only worth
  having if these would fail against the owner it replaced.
  """
  use ExUnit.Case, async: true

  alias CodeMySpecTest.AgentTransportRouter
  alias CodeMySpecTest.RecordingAgentTransport

  defp agent(project_id), do: %{id: Ecto.UUID.generate(), project_id: project_id}

  # Reports exactly one of two outcomes to `notify`: a delivery meant for
  # some other project landing here anyway, or a clean `:stop` with none
  # ever having arrived.
  defp route_then_report(project_id, notify) do
    AgentTransportRouter.route(project_id, RecordingAgentTransport)
    send(notify, {:routed, self()})

    receive do
      :stop -> send(notify, {:no_leak, self()})
      other -> send(notify, {:leaked, self(), other})
    end
  end

  test "a dispatch for one project never reaches the process that owns another" do
    project_a = Ecto.UUID.generate()
    project_b = Ecto.UUID.generate()
    test_pid = self()

    owner_b = spawn(fn -> route_then_report(project_b, test_pid) end)
    assert_receive {:routed, ^owner_b}

    AgentTransportRouter.route(project_a, RecordingAgentTransport)
    RecordingAgentTransport.dispatch_message(nil, agent(project_a), make_ref(), "for a", 1000)

    assert_receive {:agent_dispatch, _id, _ref, "for a"}

    send(owner_b, :stop)
    assert_receive {:no_leak, ^owner_b}
  end

  test "a dispatch for a project nobody routed falls back to the caller, not a stray owner" do
    project_b = Ecto.UUID.generate()
    unrouted = Ecto.UUID.generate()
    test_pid = self()

    owner_b = spawn(fn -> route_then_report(project_b, test_pid) end)
    assert_receive {:routed, ^owner_b}

    RecordingAgentTransport.dispatch_message(nil, agent(unrouted), make_ref(), "nobody's", 1000)

    assert_receive {:agent_dispatch, _id, _ref, "nobody's"}

    send(owner_b, :stop)
    assert_receive {:no_leak, ^owner_b}
  end
end
