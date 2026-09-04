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
end
