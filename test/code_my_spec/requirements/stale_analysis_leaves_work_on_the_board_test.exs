defmodule CodeMySpec.Requirements.StaleAnalysisLeavesWorkOnTheBoardTest do
  @moduledoc """
  35e80d6d — analysis and requirements are orthogonal.

  metric_flow's coder committed a story 33 fix after the last spex run read the
  tree. `bdd_specs_passing` went unsatisfied on staleness alone, and the fleet
  idled with 183 unsatisfied requirements and nothing offered. John: requirements
  are never "pending analysis".

  28d72f8a finished the job: the latest completed run answers a requirement
  however old, so an edit after the sweep moves nothing on the board. Whether
  the run saw the current code is the promote gate's question, keyed on the
  commit.
  """

  use CodeMySpecSpex.Case, async: false

  alias CodeMySpec.Environments
  alias CodeMySpec.Requirements
  alias CodeMySpec.Requirements.GraphWatcher
  alias CodeMySpecSpex.Fixtures
  alias CodeMySpecSpex.FullSatisfactionFixtures

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup ctx do
    ctx = FullSatisfactionFixtures.apply_up_to_analysis(ctx)

    # Specs green on a completed run: `bdd_specs_passing` satisfied, off the board.
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

  test "an edit after the sweep leaves the latest run's answer standing", ctx do
    assert bdd_passing(ctx.scope, :coding) == [],
           "premise: specs green on a completed run, so nothing to offer yet"

    commit_a_fix(ctx)

    assert bdd_passing(ctx.scope, :coding) == [],
           """
           the run behind bdd_specs_passing predates the edit, and it still
           answers — a requirement is never unsatisfied on staleness.
           Offered: #{inspect(Requirements.actionable_for_role(ctx.scope, :coding) |> Enum.map(& &1.name))}
           """
  end
end
