defmodule CodeMySpec.Agents.AFleetHoldIsNamedInTheRequirementsDirectiveTest do
  @moduledoc """
  783f3709: the stop-menu's `requirements` directive is where an agent is told
  to `start_task` next. While a fleet hold stands that claim is refused, so
  the directive says so instead of sending the agent toward a call that will
  only fail.
  """
  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.ComponentsFixtures
  import CodeMySpec.UsersFixtures

  alias CodeMySpec.Agents.Menu
  alias CodeMySpec.Analysis.FleetHolds
  alias CodeMySpec.Requirements

  setup do
    scope = CodeMySpec.ConfigurationsFixtures.ensure_configuration!(full_scope_fixture())
    _component = component_fixture(scope)
    Requirements.recompute(scope)
    %{scope: scope}
  end

  test "names get_next_requirement and start_task when nothing is held", %{scope: scope} do
    menu = Menu.render(scope)
    assert menu =~ "get_next_requirement"
    assert menu =~ "start_task"
    refute menu =~ "fleet hold"
  end

  test "names the hold instead, while one stands", %{scope: scope} do
    {:ok, _hold} = FleetHolds.place(scope, "load 40, five agents running tests")

    menu = Menu.render(scope)
    assert menu =~ "fleet hold is in force"
    assert menu =~ "load 40, five agents running tests"
    refute menu =~ "start_task"
  end

  test "reverts to the ordinary directive once the hold lifts", %{scope: scope} do
    {:ok, _hold} = FleetHolds.place(scope, "load 40")
    {:ok, _} = FleetHolds.lift(scope)

    menu = Menu.render(scope)
    assert menu =~ "start_task"
    refute menu =~ "fleet hold"
  end
end
