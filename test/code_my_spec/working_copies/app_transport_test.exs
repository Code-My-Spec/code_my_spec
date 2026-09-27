defmodule CodeMySpec.WorkingCopies.AppTransportTest do
  @moduledoc """
  `AppTransport` against the registry a real join populates.

  Mirrors `CodeMySpec.Agents.TransportReachesAConnectedHarnessTest`, written
  after that module shipped looking up a registry that did not exist and
  every call silently read as "not connected" — a defect no test caught
  because every spex swaps the transport for an in-process double. This
  drives the real module directly and asserts only what it is for: it finds
  a connected copy and does not find an absent one.
  """

  use CodeMySpecTest.DataCase, async: false

  import CodeMySpec.UsersFixtures

  alias CodeMySpec.Analysis
  alias CodeMySpec.WorkingCopies.AppTransport

  test "a copy nothing is holding is reported unreachable" do
    scope = full_scope_fixture()

    assert {:error, :harness_not_connected} =
             AppTransport.ensure_app_running(scope.active_working_copy_id, 100)

    assert {:error, :harness_not_connected} =
             AppTransport.restart_app(scope.active_working_copy_id, 100)

    assert {:error, :harness_not_connected} =
             AppTransport.stop_app(scope.active_working_copy_id, 100)
  end

  test "a connected copy is found, rather than reported unreachable" do
    scope = full_scope_fixture()

    :ok = register_holder(scope.active_working_copy_id)

    # The transport reaches us. We are not a channel, so the call fails on
    # the far side (this process has no `handle_call` for it) rather than
    # being refused before it leaves — that distinction is the property
    # under test, the same way the agent transport's own test reads it.
    result = AppTransport.ensure_app_running(scope.active_working_copy_id, 100)

    refute result == {:error, :harness_not_connected},
           "the transport could not find a copy that is registered and held " <>
             "by a live process"
  end

  defp register_holder(working_copy_id) do
    test = self()

    {:ok, _pid} =
      Task.start_link(fn ->
        Analysis.register_executor(working_copy_id, self(), "/tmp/a-copy")
        send(test, :registered)
        Process.sleep(:infinity)
      end)

    receive do
      :registered -> :ok
    after
      2_000 -> flunk("the holder never registered")
    end
  end
end
