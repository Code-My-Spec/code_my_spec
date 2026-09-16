defmodule CodeMySpec.Agents.SwitchingACopyOnAsksForAScanTest do
  @moduledoc """
  Switching a working copy on rings the bell itself, and the bell is only worth
  ringing if there is a graph behind it.

  `wake_roles/3` renders each role's menu from what the graph holds at that
  instant. On a copy nothing has scanned, that is empty for every role, and not
  as a corner case: `personas_complete` reads a verdict `Files.Scanner` decides
  at sync time, and it gates `stories_exist`, which gates `technical_strategy`
  and everything after it. The project chain is one line, so an unscanned copy
  has an empty actionable set whatever is on disk — and the first switch-on is
  exactly the moment somebody expects their agents to start. Issue `a0780389`,
  found while making criterion 3185 of story 1004 green.

  The scan is asked of the harness rather than done here because this side does
  not have the files. On the light harness the server holds no working copy at
  all, which is why `Files.Scanner` runs on the machine with the disk and this
  one reads its verdict. So the fix is a request, and what comes back arrives on
  the ordinary manifest path: inputs are announced, the watcher recomputes, and
  `wake_project_roles/2` rings against a real graph.
  """
  use CodeMySpecTest.DataCase, async: false

  import CodeMySpec.UsersFixtures
  import CodeMySpec.DevicesFixtures

  alias CodeMySpec.Agents
  alias CodeMySpec.Analysis
  alias CodeMySpec.Requirements.GraphWatcher
  alias Ecto.Adapters.SQL.Sandbox

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})

    scope = full_scope_fixture()

    {:ok, copy} =
      CodeMySpec.WorkingCopies.issue(scope, nil,
        label: "a checkout nothing has scanned",
        device: device_fixture(scope)
      )

    %{scope: scope, copy: copy}
  end

  # Stands in for the channel process, which is what the registry holds. Same
  # shape as `CodeMySpec.Analysis.RequestRescanTest` uses, because the thing
  # being observed is the same push.
  defp registered_channel(working_copy_id) do
    test = self()

    pid =
      spawn(fn ->
        :ok = Analysis.register_executor(working_copy_id, "test:#{System.unique_integer()}")
        send(test, {:registered, self()})

        receive do
          message -> send(test, {:channel_got, message})
        end
      end)

    assert_receive {:registered, ^pid}, 1_000
    pid
  end

  test "switching a copy on asks its harness to scan it", %{scope: scope, copy: copy} do
    _channel = registered_channel(copy.id)

    assert {:ok, _count} = Agents.set_copy_continuous(scope, copy.id, true)

    assert_receive {:channel_got, :rescan}, 1_000, """
    A copy was switched on and nothing asked its harness to scan it.

    The switch is the moment a person expects their agents to start,
    and on a copy that has never been scanned every role's menu is
    empty — so the bell rings and nobody moves. Recovery is
    undiscoverable: something else has to move the graph before
    anyone is told anything.
    """

    settle(scope)
  end

  test "switching a copy off asks for nothing", %{scope: scope, copy: copy} do
    _channel = registered_channel(copy.id)

    assert {:ok, _count} = Agents.set_copy_continuous(scope, copy.id, false)

    refute_receive {:channel_got, :rescan}, 200

    # Switching off is the absence of a message, which is what letting an agent
    # stop means. A scan here would be work nobody asked for on a copy whose
    # whole point is that it has been put down.
  end

  test "a copy whose harness is not connected is still switched on", %{scope: scope, copy: copy} do
    # No `registered_channel/1`: nothing is listening for this copy, which is
    # the ordinary state of a machine that is off.
    assert {:ok, _count} = Agents.set_copy_continuous(scope, copy.id, true),
           """
           An unreachable harness failed the switch.

           The flag is this side's to set, the scan is the other side's to run,
           and a copy whose machine is off is precisely the one somebody is most
           likely to be switching on ahead of starting it. It scans when its
           harness comes back.
           """

    settle(scope)
  end

  # Switching on starts a watcher, and a pass still running when the test body
  # returns outlives the sandbox owner — which surfaces as
  # `DBConnection.ConnectionError ... client exited` against whichever file is
  # unlucky, not against this one. `GraphWatcher`'s own moduledoc and
  # `CodeMySpecSpex.Case` both document this shape at length. Settling inside
  # the test is the local half: the pass finishes while its owner is still alive.
  defp settle(scope), do: :ok = GraphWatcher.settle(scope.active_project_id)
end
