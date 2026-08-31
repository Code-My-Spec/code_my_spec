defmodule CodeMySpecWeb.HarnessBrowserStatusTest do
  @moduledoc """
  The reason a machine has no browser tools, all the way to the row.

  Issue 02b03d04. `machine_tools` is `[]` for a machine with no vibium and for
  one whose vibium will not answer, and only the second is something an operator
  can act on. `CmsHarness.BrowserStatusTest` covers the harness deciding which
  it is; this covers the decision surviving the join.

  Worth its own test rather than an assertion inside the join test: the failure
  it guards is silence, and silence is what a join test that only checks the
  reply would report as success.
  """

  # Not async: the channel takes the project's advisory lock on join.
  use CodeMySpecTest.DataCase, async: false

  import CodeMySpec.DevicesFixtures
  import CodeMySpec.UsersFixtures
  import Phoenix.ChannelTest

  @endpoint CodeMySpecWeb.Endpoint

  alias CodeMySpec.WorkingCopies
  alias CodeMySpecWeb.HarnessProjectChannel
  alias CodeMySpecWeb.UserSocket
  alias Ecto.Adapters.SQL.Sandbox

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    scope = full_scope_fixture()
    %{scope: scope, topic: "harness_project:#{scope.active_project_id}"}
  end

  defp join_reporting(scope, topic, extra) do
    payload =
      Map.merge(
        %{
          "label" => "the harness at /workspace/app",
          "harness_id" => scope.active_working_copy_id,
          "device" => %{"id" => device_fixture(scope).id}
        },
        extra
      )

    socket(UserSocket, "browser_status_test", %{scope: scope})
    |> subscribe_and_join(HarnessProjectChannel, topic, payload)
  end

  defp copy(scope) do
    {:ok, copy} = WorkingCopies.fetch(scope.active_working_copy_id)
    copy
  end

  test "a machine that has no browser says so", %{scope: scope, topic: topic} do
    {:ok, _, _} =
      join_reporting(scope, topic, %{
        "machine_tools" => [],
        "browser_status" => %{"status" => "absent"}
      })

    assert copy(scope).browser_status == "absent"
    assert copy(scope).browser_error == nil
  end

  test "a machine whose browser would not answer says that instead", %{
    scope: scope,
    topic: topic
  } do
    {:ok, _, _} =
      join_reporting(scope, topic, %{
        "machine_tools" => [],
        "browser_status" => %{
          "status" => "unreachable",
          "error" => "this machine's browser did not say what it offers"
        }
      })

    recorded = copy(scope)

    assert recorded.browser_status == "unreachable",
           "both machines report no tools, so the row is the only place the difference " <>
             "can live. Without it an agent is recorded with tools that cannot look at " <>
             "a page and nothing says so — it does not fail, it never looks."

    assert recorded.browser_error =~ "did not say what it offers",
           "the reason is what makes the state actionable rather than merely " <>
             "distinguishable."
  end

  test "a harness that says nothing about a browser is not an error", %{
    scope: scope,
    topic: topic
  } do
    assert {:ok, _, _} = join_reporting(scope, topic, %{"machine_tools" => []})

    assert copy(scope).browser_status == nil,
           "null is the column's 'has not said', matching machine_tools beside it. An " <>
             "older harness that sends nothing must join anyway — refusing would take " <>
             "the checkout down for the tools it does have."
  end
end
