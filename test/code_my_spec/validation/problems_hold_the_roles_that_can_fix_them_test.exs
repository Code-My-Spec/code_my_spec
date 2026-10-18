defmodule CodeMySpec.Validation.ProblemsHoldTheRolesThatCanFixThemTest do
  @moduledoc """
  Problems are information in the menu, never a class of work (John,
  2026-10-18): they gate at promotion. So no role is held by them, and only a
  role that can fix them is told how many there are.

  Before that, problems were a class scoped to the roles that fix code. On
  2026-09-06 a QA agent said, four times in fifteen minutes, that it could not
  read the 47 Spex findings holding it, could not fix them and could not stop.
  The scoping survives as who sees the count.
  """
  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.UsersFixtures
  import CodeMySpec.ProblemsFixtures

  alias CodeMySpec.Agents.Agent
  alias CodeMySpec.Agents.Menu
  alias CodeMySpec.Sessions.Task

  setup do
    scope = full_scope_fixture()

    # One error is enough: the class is live or it is not.
    problem_fixture(scope, %{severity: :error, source: "spex"})

    %{scope: scope}
  end

  defp live_classes(scope, role), do: scope |> Menu.live(role) |> Keyword.keys()

  # An open task, so the menu has a class to render the count beside.
  defp holding_a_task do
    %Agent{
      tasks: [
        %Task{
          id: Ecto.UUID.generate(),
          status: :active,
          requirement_name: "implementation_file",
          started_at: DateTime.utc_now()
        }
      ]
    }
  end

  test "problems are no role's class of work", %{scope: scope} do
    for role <- [:coding, :main, :qa, :product, nil] do
      refute :problems in live_classes(scope, role), "#{inspect(role)} was held by problems"
    end
  end

  test "nothing directs any role to the problems", %{scope: scope} do
    for role <- [:coding, :qa, nil] do
      refute Menu.render(scope, false, role) =~ ~r/Next:[^\n]*list_problems/
    end
  end

  test "a coding agent is told the count, as information", %{scope: scope} do
    menu = Menu.render(scope, false, :coding, holding_a_task())

    assert menu =~ "For information: 1 problem is recorded"
    refute menu =~ ~r/Next:[^\n]*list_problems/
  end

  # a31f1cd6 step 4b, John: "holds_problems is coding only".
  test "QA is not told — a compile error elsewhere is not a move it has", %{scope: scope} do
    refute Menu.render(scope, false, :qa, holding_a_task()) =~ "For information"
  end
end
