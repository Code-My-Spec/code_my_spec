defmodule CodeMySpec.Agents.Main.TheCadenceCanBeTurnedBackOnTest do
  @moduledoc """
  Standing down had a door and resuming did not: `resume/1` was reachable only
  by starting a main agent, so anything that stood a project down could not put
  it back without one.
  """

  use CodeMySpecTest.DataCase, async: false

  import CodeMySpec.UsersFixtures

  alias CodeMySpec.Agents.Main, as: MainAgent
  alias CodeMySpec.Agents.Main.Cadence

  test "standing down and resuming both work, and resuming leaves a timer" do
    scope = full_scope_fixture()

    :ok = MainAgent.stand_down(scope)
    refute Cadence.running?(scope)

    :ok = MainAgent.resume(scope)
    assert Cadence.running?(scope)
  end

  test "the interval is set rather than assumed" do
    scope = full_scope_fixture()

    :ok = MainAgent.set_cadence_interval(scope, 300)
    assert MainAgent.cadence_interval(scope) == 300
  end
end
