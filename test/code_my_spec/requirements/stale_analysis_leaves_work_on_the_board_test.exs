defmodule CodeMySpec.Requirements.StaleAnalysisLeavesWorkOnTheBoardTest do
  @moduledoc """
  35e80d6d — analysis and requirements are orthogonal.

  metric_flow's coder committed a story 33 fix after the last spex run read the
  tree. `bdd_specs_passing` went unsatisfied on staleness alone, and the fleet
  idled with 183 unsatisfied requirements and nothing offered. John: requirements
  are never "pending analysis" — an unsatisfied one sits on the board, ready to
  work, whatever the freshness of the run behind it. Freshness matters only when
  a task is evaluated.
  """

  use CodeMySpecSpex.Case, async: false

  alias CodeMySpec.Environments
  alias CodeMySpec.Requirements
  alias CodeMySpec.Requirements.GraphWatcher
  alias CodeMySpec.Validation.Menu
  alias CodeMySpecSpex.Fixtures
  alias CodeMySpecSpex.FullSatisfactionFixtures

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup ctx do
    ctx = FullSatisfactionFixtures.apply_up_to_analysis(ctx)

    # Specs green on a fresh run: `bdd_specs_passing` satisfied, off the board.
    Fixtures.fresh_analysis_runs(ctx.scope)
    :ok = GraphWatcher.settle(ctx.scope)

    ctx
  end

  defp bdd_passing(scope, role) do
    scope
    |> Requirements.actionable_for_role(role)
    |> Enum.filter(&(&1.name == "bdd_specs_passing"))
  end

  # 0904ade: code every analyzer reads moves after the sweep.
  defp commit_a_fix(ctx) do
    :ok =
      Environments.write_file(
        ctx.environment,
        "lib/reservations.ex",
        "defmodule Reservations do\n  def fixed, do: :story_33\nend\n"
      )

    :ok = Fixtures.sync_files(ctx.scope)
    :ok = GraphWatcher.settle(ctx.scope)
  end

  test "a requirement stale analysis unsatisfied is offered to its role", ctx do
    assert bdd_passing(ctx.scope, :coding) == [],
           "premise: specs green on a fresh run, so nothing to offer yet"

    commit_a_fix(ctx)

    assert [node] = bdd_passing(ctx.scope, :coding),
           """
           spex is stale for this tree and bdd_specs_passing is unsatisfied — it
           must sit on the board for coding rather than read as nothing to do.
           Offered: #{inspect(Requirements.actionable_for_role(ctx.scope, :coding) |> Enum.map(& &1.name))}
           """

    assert node.entity_id == ctx.story.id
  end

  test "the coder's stop menu names it", ctx do
    commit_a_fix(ctx)

    menu = Menu.render(ctx.scope, true, :coding, nil)

    # The menu counts rather than names (the model picks, 2026-09-05), so "not
    # nothing" is the claim: an empty menu is the loop's terminus.
    assert menu =~ ~r/Next: [1-9]\d* requirement/,
           "the continuing coder must be pointed at the work, got: #{inspect(menu)}"
  end
end
