defmodule CodeMySpec.Analysis.FleetHoldsTest do
  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.UsersFixtures

  alias CodeMySpec.Analysis.FleetHolds

  setup do
    %{scope: full_scope_fixture()}
  end

  test "no hold is active on a fresh project", %{scope: scope} do
    refute FleetHolds.active(scope)
  end

  test "placing a hold makes it the active one", %{scope: scope} do
    assert {:ok, hold} = FleetHolds.place(scope, "load 40, five agents running tests")
    assert hold.status == :active
    assert hold.reason == "load 40, five agents running tests"
    assert hold.placed_by == "operator"
    assert FleetHolds.active(scope).id == hold.id
  end

  # The operator in 783f3709 repeated the same broadcast four minutes later;
  # that must not mint a second row and trip the one-active-per-project index.
  test "placing a hold while one already stands answers the standing hold", %{scope: scope} do
    assert {:ok, first} = FleetHolds.place(scope, "load 40")
    assert {:ok, second} = FleetHolds.place(scope, "load 40, repeated")
    assert second.id == first.id
    assert second.reason == "load 40"
  end

  test "lifting the active hold clears it", %{scope: scope} do
    {:ok, hold} = FleetHolds.place(scope, "load 40")
    assert {:ok, lifted} = FleetHolds.lift(scope)
    assert lifted.id == hold.id
    assert lifted.status == :lifted
    assert lifted.lifted_at
    refute FleetHolds.active(scope)
  end

  test "lifting with nothing active answers :no_active_hold", %{scope: scope} do
    assert {:error, :no_active_hold} = FleetHolds.lift(scope)
  end

  test "a lifted hold can be followed by a new one", %{scope: scope} do
    {:ok, first} = FleetHolds.place(scope, "load 40")
    {:ok, _} = FleetHolds.lift(scope)
    assert {:ok, second} = FleetHolds.place(scope, "load 50")
    assert second.id != first.id
    assert FleetHolds.active(scope).id == second.id
  end

  test "the refusal names the reason and says what is and is not affected", %{scope: scope} do
    {:ok, hold} = FleetHolds.place(scope, "load 40, five agents running tests")
    text = FleetHolds.refusal(hold)
    assert text =~ "fleet hold is in force"
    assert text =~ "load 40, five agents running tests"
    assert text =~ "refused until it lifts"
    assert text =~ "unaffected"
  end
end
