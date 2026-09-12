defmodule CodeMySpec.AgentsEnsureCopyAgentsTest do
  @moduledoc """
  A working copy's roster: product, coding and QA, started once.

  The agents belong to the copy rather than to the epic it was given, so this is
  idempotent by role — a second epic onto the same copy starts nothing, which is
  what makes it cheaper than the first and what keeps discarding the copy
  meaningful.
  """

  use CodeMySpecTest.DataCase, async: false

  import CodeMySpec.UsersFixtures

  alias CodeMySpec.Agents
  alias CodeMySpec.WorkingCopies

  setup do
    scope = full_scope_fixture()
    {:ok, _} = CodeMySpecSpex.Fixtures.connect_provider(scope, :openai)

    # A real checkout that is NOT the project's main one. The main copy holds
    # exactly one agent and it is the project's own — `main_copy_is_free/2` —
    # so a roster of three cannot go there, and that rule is correct: two
    # agents in one checkout are two processes editing one tree.
    device = CodeMySpec.DevicesFixtures.device_fixture(scope)
    n = System.unique_integer([:positive])

    # The project's main checkout first. A project's *only* checkout becomes the
    # main one (`report_root/2` → `only_checkout?/1`), so without this the epic's
    # copy would be main and the roster would be refused — which is the same
    # structural truth the story turns on: the main checkout holds the project's
    # own agent, and an epic's work happens on a second one.
    {:ok, main} = WorkingCopies.issue(scope, nil, root: "/tmp/main-#{n}", device: device)
    {:ok, _main} = WorkingCopies.report_root(main, "/tmp/main-#{n}")

    root = "/tmp/roster-#{n}"

    {:ok, copy} =
      WorkingCopies.issue(scope, nil, root: root, device: device, label: "an epic's copy")

    # `issue/3` records the row; the root arrives when the checkout reports it,
    # which is what makes it a checkout rather than a row.
    {:ok, copy} = WorkingCopies.report_root(copy, root)

    %{scope: scope, copy: copy}
  end

  test "reports what it started and what it could not", %{scope: scope, copy: copy} do
    result = Agents.ensure_copy_agents(scope, %{id: copy.id, root: copy.root || "/tmp/roster"})

    assert result.failed == [],
           "a role could not be started: #{inspect(result.failed)}"

    assert Enum.map(result.started, & &1.role) |> Enum.sort() == [:coding, :product, :qa]
  end

  test "a second call starts nothing", %{scope: scope, copy: copy} do
    arg = %{id: copy.id, root: copy.root || "/tmp/roster"}

    first = Agents.ensure_copy_agents(scope, arg)
    second = Agents.ensure_copy_agents(scope, arg)

    assert length(first.started) == 3
    assert second.started == [], "a second epic started more agents: #{inspect(second)}"
  end

  describe "a caller that names the roster" do
    # QA could not test any criterion about delivery *to* a main agent, because
    # the only sanctioned route to disposable agents always staffed exactly
    # these three. The alternatives were reaching into the real project or
    # writing an agent row behind the tool surface, and both defeat the point of
    # a sandbox — so story 1011's criterion 3265 came back `partial` with
    # nothing observed to be wrong (fcbcc3ed).
    test "gets exactly what it asked for", %{scope: scope, copy: copy} do
      arg = %{id: copy.id, root: copy.root || "/tmp/roster"}

      result = Agents.ensure_copy_agents(scope, arg, [:main])

      assert result.failed == [], "main could not be started: #{inspect(result.failed)}"
      assert Enum.map(result.started, & &1.role) == [:main]
    end

    test "the default is still the three that build something", %{scope: scope, copy: copy} do
      assert Agents.copy_roles() == [:product, :coding, :qa]

      arg = %{id: copy.id, root: copy.root || "/tmp/roster"}
      result = Agents.ensure_copy_agents(scope, arg)

      assert Enum.map(result.started, & &1.role) |> Enum.sort() == [:coding, :product, :qa],
             "a copy nobody staffed deliberately should not gain a main agent — the main " <>
               "agent is the project's, and one per worktree gives a project as many " <>
               "orchestrators as it has checkouts"
    end

    test "is still idempotent by role", %{scope: scope, copy: copy} do
      arg = %{id: copy.id, root: copy.root || "/tmp/roster"}

      assert [:main] =
               Agents.ensure_copy_agents(scope, arg, [:main]).started |> Enum.map(& &1.role)

      assert [] = Agents.ensure_copy_agents(scope, arg, [:main]).started
    end

    # Asking for one role must not quietly start the other three as well, which
    # is what a roster that ignored its argument would do.
    test "naming one role does not staff the rest", %{scope: scope, copy: copy} do
      arg = %{id: copy.id, root: copy.root || "/tmp/roster"}

      Agents.ensure_copy_agents(scope, arg, [:main])

      roles =
        scope
        |> Agents.list_agents()
        |> Enum.filter(&(&1.working_copy_id == copy.id and &1.status != :stopped))
        |> Enum.map(& &1.role)

      assert roles == [:main]
    end
  end
end
