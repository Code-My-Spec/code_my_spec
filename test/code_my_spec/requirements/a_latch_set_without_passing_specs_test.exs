defmodule CodeMySpec.Requirements.ALatchSetWithoutPassingSpecsTest do
  @moduledoc """
  `specs_ready` must not be able to claim specs passed when they are red.

  The gate that sets the latch matched a spex problem to a story by parsing the
  spec's directory name. Spex directories are named from `story.number` in some
  projects and `story.id` in others, so the comparison matched nothing for
  whichever convention it was not written for — and "no failing specs found"
  is the branch that latches.

  Measured on Broken Oaths 2026-09-08: 38 of 54 directories were id-prefixed,
  47 of 61 stories carried `specs_ready: true`, and 127 specs were red for
  features nobody had written. Because the graph read the field and the field
  said yes, `bdd_specs_passing` was not actionable on any of them, so the only
  coding work the graph could still offer was writing specs for stories that
  had none. Three coding agents did exactly that, across ten stories.

  John, reading the backlog: "those specs should not be contributing to the
  problems yet because the development's not done... they're supposed to go
  through to specs passing before they get latched in."

  Both halves of that are tested here: the latch cannot be set by a lookup that
  failed, and it cannot survive a fresh run that contradicts it.
  """
  use CodeMySpecTest.DataCase, async: true

  alias CodeMySpec.Requirements.SpecsPassingChecker
  alias CodeMySpec.Stories

  import CodeMySpec.AnalysisFixtures
  import CodeMySpec.ProblemsFixtures
  import CodeMySpec.StoriesFixtures
  import CodeMySpec.UsersFixtures

  # Named from the story's *id*, which is the convention that used to defeat
  # the matching. A number-named directory would pass even with the bug in.
  defp id_named_spec_path(story),
    do: "test/spex/#{story.id}_some_feature/criterion_1_spex.exs"

  defp story_with_red_specs(scope, opts \\ []) do
    story = story_fixture(scope, %{title: "Story With Red Specs"})
    path = id_named_spec_path(story)

    {_n, _} =
      CodeMySpec.Files.upsert_files(scope, [
        %{path: path, role: :bdd_spec, story_id: story.id, valid: true, mtime: DateTime.utc_now()}
      ])

    maybe_add_red_problem(Keyword.get(opts, :red, true), scope, path)

    {:ok, story} = Stories.set_specs_ready(scope, story, true)
    story
  end

  defp maybe_add_red_problem(true, scope, path) do
    problem_fixture(scope, %{
      source: "spex",
      source_type: :test,
      file_path: path,
      message: "no match of right hand side value: []",
      severity: :error,
      category: "spex"
    })
  end

  defp maybe_add_red_problem(false, _scope, _path), do: :ok

  setup do
    %{scope: full_scope_fixture()}
  end

  test "a story marked ready whose own specs are red reads unsatisfied", %{scope: scope} do
    story = story_with_red_specs(scope)
    fresh_analysis_runs_fixture(scope)

    assert {false, details} = SpecsPassingChecker.passing?(scope, story)
    assert details.reason =~ "fail on the current spex run"
  end

  test "and the reason says the latch was set without them passing", %{scope: scope} do
    story = story_with_red_specs(scope)
    fresh_analysis_runs_fixture(scope)

    {false, details} = SpecsPassingChecker.passing?(scope, story)

    assert details.reason =~ "without them passing",
           "an agent told only that a requirement is unsatisfied goes looking for " <>
             "work it already did; the latch being wrong is the actionable part"
  end

  test "a story marked ready with green specs still reads satisfied", %{scope: scope} do
    story = story_with_red_specs(scope, red: false)
    fresh_analysis_runs_fixture(scope)

    assert {true, _} = SpecsPassingChecker.passing?(scope, story)
  end

  test "a story that was never marked ready reads unsatisfied", %{scope: scope} do
    story = story_fixture(scope, %{title: "Not Started"})

    assert {false, details} = SpecsPassingChecker.passing?(scope, story)
    assert details.reason =~ "not gone green"
  end

  # The asymmetry that lets the node exist at all. bab2f792 removed
  # `bdd_specs_passing` because freshness was re-evaluated forever, so nearly
  # any edit dropped a finished story back to "analysis pending" and clamped
  # `qa_complete` behind it. A stale run is not evidence of anything.
  test "a stale spex run cannot clear the latch", %{scope: scope} do
    story = story_with_red_specs(scope)

    # No fresh run recorded — the red problems above are from a run that no
    # longer covers the current code.
    assert {true, details} = SpecsPassingChecker.passing?(scope, story)
    assert details.status =~ "no fresh spex run"
  end

  # A failing spec that belongs to somebody else is somebody else's gate. This
  # is the same argument the per-story prompt scoping was built on: an agent
  # shown another story's failures goes and edits components it was never asked
  # to touch.
  test "another story's red specs do not clear this story's latch", %{scope: scope} do
    _theirs = story_with_red_specs(scope)

    mine = story_fixture(scope, %{title: "Mine"})

    {_n, _} =
      CodeMySpec.Files.upsert_files(scope, [
        %{
          path: id_named_spec_path(mine),
          role: :bdd_spec,
          story_id: mine.id,
          valid: true,
          mtime: DateTime.utc_now()
        }
      ])

    {:ok, mine} = Stories.set_specs_ready(scope, mine, true)
    fresh_analysis_runs_fixture(scope)

    assert {true, _} = SpecsPassingChecker.passing?(scope, mine)
  end
end
