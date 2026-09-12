defmodule CodeMySpec.MainAgent.CadenceWiringTest do
  @moduledoc """
  That something actually starts the cadence.

  The spex for story 1059 start the GenServer themselves through the Fixtures
  bridge. That proves the timer loop works once running, and is structurally
  incapable of proving anything starts it — so the story shipped with
  `Cadence.start_link/1` called from nowhere, no Registry, no supervisor, and
  `running?/1` answering false in production for every project. QA found it by
  grepping the running build; no test could have, because no test asked this
  question.

  This asks it. It drives the real application's supervision tree rather than
  starting anything itself, which is the only way the assertion means what it
  says.
  """

  use CodeMySpecTest.DataCase, async: false

  import CodeMySpec.UsersFixtures

  alias CodeMySpec.MainAgent

  setup do
    scope = full_scope_fixture()

    on_exit(fn ->
      CodeMySpec.MainAgent.CadenceRegistry
      |> Registry.lookup(scope.active_project_id)
      |> Enum.each(fn {pid, _} ->
        DynamicSupervisor.terminate_child(CodeMySpec.MainAgent.CadenceSupervisor, pid)
      end)
    end)

    %{scope: scope}
  end

  test "the registry and supervisor the cadence needs are in the running tree" do
    assert Process.whereis(CodeMySpec.MainAgent.CadenceRegistry),
           """
           CadenceRegistry is not started. `Cadence.start_link/1` names itself
           through `{:via, Registry, {CadenceRegistry, project_id}}`, so without
           it the process cannot start at all — and the only symptom is a main
           agent that is never woken.
           """

    assert Process.whereis(CodeMySpec.MainAgent.CadenceSupervisor),
           "CadenceSupervisor is not started, so nothing can start a project's cadence."
  end

  test "ensure_cadence starts a project's cadence, and running? then says so", %{scope: scope} do
    # `cadence_alive?/1`, not `cadence_running?/1`. The latter answers intent —
    # "has this project stood down" — and is true for every project that never
    # has, including one with no timer at all. That conflation is exactly how
    # nothing starting the cadence stayed invisible.
    refute MainAgent.cadence_alive?(scope),
           "a project nobody has started should not already have a timer"

    assert {:ok, pid} = MainAgent.ensure_cadence(scope)
    assert is_pid(pid)
    assert Process.alive?(pid)

    assert MainAgent.cadence_alive?(scope),
           """
           The cadence was started and `cadence_alive?/1` still says no.

           That is the production state QA found, in its honest form: a
           project meant to be woken, with nothing there to wake it. The
           health signal said yes throughout, because it was reading intent.
           """
  end

  test "asking twice is the same cadence, not a second one", %{scope: scope} do
    assert {:ok, first} = MainAgent.ensure_cadence(scope)
    assert {:ok, second} = MainAgent.ensure_cadence(scope)

    assert first == second,
           """
           A second call started a second timer for one project, which wakes the
           main agent twice an interval and costs a model call each time.
           `ensure_*` has to be idempotent — it is called from request paths.
           """
  end

  test "a scope with no project is refused rather than crashing" do
    assert {:error, :no_project} = MainAgent.ensure_cadence(%CodeMySpec.Users.Scope{})
  end
end
