defmodule CodeMySpec.Validation.ProblemsHoldTheRolesThatCanFixThemTest do
  @moduledoc """
  A directive nobody can act on is the thing this module exists to stop.

  Requirements were scoped by role — story 538's R10, so a coding agent is not
  held open by product's queue — and problems never were. So every role was
  held by every project error.

  On 2026-09-06 the war-epic QA agent said so, four times in fifteen minutes:
  "`list_problems` is not available to this QA role, so I cannot inspect the 47
  Spex findings." It could not read them, could not fix them, and could not
  stop. John: "it shouldn't get blocked by problems."
  """
  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.UsersFixtures
  import CodeMySpec.ProblemsFixtures

  alias CodeMySpec.Validation.Menu

  setup do
    scope = full_scope_fixture()

    # One error is enough: the class is live or it is not.
    problem_fixture(scope, %{severity: :error, source: "spex"})

    %{scope: scope}
  end

  defp live_classes(scope, role), do: scope |> Menu.live(role) |> Keyword.keys()

  test "a coding agent is held — it fixes code", %{scope: scope} do
    assert :problems in live_classes(scope, :coding)
  end

  test "main is held — it does everything", %{scope: scope} do
    assert :problems in live_classes(scope, :main)
  end

  # The report. QA tests one story; a compile error somewhere else is not a
  # move it has.
  test "QA is not held", %{scope: scope} do
    refute :problems in live_classes(scope, :qa)
  end

  test "product is not held — it writes specs", %{scope: scope} do
    refute :problems in live_classes(scope, :product)
  end

  # Every caller outside the loop: the project's own count, which is what a
  # person asking about the tree wants.
  test "no role counts the project's problems", %{scope: scope} do
    assert :problems in live_classes(scope, nil)
  end

  # The whole point is that the refusal stops. A QA agent with nothing else
  # live must be allowed to end its turn.
  test "a QA agent with only problems outstanding is not refused", %{scope: scope} do
    assert Menu.render(scope, false, :qa) == ""
  end

  test "a coding agent with the same problems is still refused", %{scope: scope} do
    menu = Menu.render(scope, false, :coding)

    assert menu =~ "problem"
    assert menu =~ "list_problems"
  end
end
