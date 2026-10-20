defmodule CodeMySpec.Promotion.TheGateHoldsEverythingTest do
  @moduledoc """
  Zero problems on the promoting copy (John, 2026-10-05: every red spex refuses,
  latched or not).

  Compiler, credo and exunit findings refuse at :error or :warning; :info is
  advisory. A red spex refuses whatever its story's state.

  Drives `Promotion.gate/3` directly: the gate reads the database and never
  touches git, so there is nothing to shell out to.
  """

  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.DevicesFixtures
  import CodeMySpec.ProblemsFixtures
  import CodeMySpec.StoriesFixtures
  import CodeMySpec.UsersFixtures

  alias CodeMySpec.Analysis.Run
  alias CodeMySpec.AnalysisFixtures
  alias CodeMySpec.Promotion
  alias CodeMySpec.WorkingCopies

  # The commit every analyzer's run started and finished on.
  @head "4444444444444444444444444444444444444444"

  setup do
    scope = full_scope_fixture()

    {:ok, copy} =
      WorkingCopies.issue(scope, nil, label: "the promoting copy", device: device_fixture(scope))

    scope = %{scope | active_working_copy_id: copy.id}
    AnalysisFixtures.fresh_analysis_runs_fixture(scope, Run.sources(), commit: @head)
    %{scope: scope}
  end

  # A second checkout on the same project, as a harness joining would mint one.
  defp issue_scope(scope, label) do
    {:ok, copy} =
      WorkingCopies.issue(scope, nil, label: label, device: device_fixture(scope))

    %{id: copy.id, scope: %{scope | active_working_copy_id: copy.id}}
  end

  defp red_spec(scope, story) do
    [criterion | _] = story.criteria
    path = CodeMySpec.BddSpecs.spec_file_path(story, criterion)

    CodeMySpec.Files.upsert_files(scope, [
      %{
        path: path,
        role: :bdd_spec,
        story_id: story.id,
        criterion_number: criterion.number,
        valid: true,
        mtime: DateTime.utc_now()
      }
    ])

    problem_fixture(scope, %{
      source: "spex",
      source_type: :test,
      file_path: path,
      message: "no match of right hand side value: []",
      severity: :error,
      category: "spex"
    })

    path
  end

  test "an open exunit failure refuses, naming the count and the failure", %{scope: scope} do
    problem_fixture(scope, %{
      source: "exunit",
      source_type: :test,
      file_path: "test/my_app_web/live/settings_test.exs",
      line: 12,
      message: "Expected truthy, got false",
      category: "test_failure",
      rule: nil
    })

    assert {:error, %{reason: reason}} = Promotion.gate(scope, @head)
    assert reason =~ "1 exunit"
    assert reason =~ "test/my_app_web/live/settings_test.exs:12"
  end

  test "a credo :warning refuses", %{scope: scope} do
    problem_fixture(scope, %{severity: :warning})

    assert {:error, %{reason: reason}} = Promotion.gate(scope, @head),
           "a credo :warning still reached main"

    assert reason =~ "1 credo"
  end

  test "a credo :info does not refuse", %{scope: scope} do
    problem_fixture(scope, %{severity: :info})

    assert {:ok, _certified} = Promotion.gate(scope, @head),
           "low-priority credo findings are advisory, not a promotion blocker"
  end

  test "a compiler warning refuses", %{scope: scope} do
    problem_fixture(scope, %{
      source: "compiler",
      source_type: :static_analysis,
      severity: :warning,
      message: "variable \"x\" is unused",
      category: "warning",
      rule: nil
    })

    assert {:error, %{reason: reason}} = Promotion.gate(scope, @head)
    assert reason =~ "1 compiler"
  end

  test "a red spex refuses, whatever its story's state", %{scope: scope} do
    story = story_fixture(scope, %{title: "Written Ahead Of Its Code"})
    path = red_spec(scope, story)

    assert {:error, %{reason: reason}} = Promotion.gate(scope, @head)
    assert reason =~ "1 spex"
    assert reason =~ path
  end

  # c2975537: bulk-parking (`ready_for_dev` true -> false) clears a story's
  # specs-ready latch via `Story.clear_specs_ready_on_readiness_change/1`,
  # and a promotion once read the cleared latch as "this story's spex may
  # stay red" (fixed, f8d823f7e, before this test existed). This drives the
  # exact sequence of the 2026-10-03 incident — latched, then parked — rather
  # than only a story that was never latched, so a regression on parking
  # specifically would be caught even if some other path still checked the
  # latch.
  test "parking a story that was latched does not excuse its red spex", %{scope: scope} do
    story = story_fixture(scope, %{title: "Shipped, Then Reopened For A Refactor"})
    {:ok, story} = CodeMySpec.Stories.set_specs_ready(scope, story, true)
    assert story.specs_ready

    {:ok, story} = CodeMySpec.Stories.update_story(scope, story, %{ready_for_dev: false})

    refute story.specs_ready,
           "parking should still clear the latch -- this test is about what " <>
             "happens next, not about restoring the latch"

    path = red_spec(scope, story)

    assert {:error, %{reason: reason}} = Promotion.gate(scope, @head),
           "a parked story's red spex let a promotion through — the exact " <>
             "shape of the 2026-10-03 incident (c2975537)"

    assert reason =~ "1 spex"
    assert reason =~ path
  end

  # `02796b61`. `gate/3` passes the scope it was handed straight to
  # `blocking_problems/2`, and with no copy on that scope the problem read
  # falls back to `WorkingCopies.default_id/1`. So a caller with no working
  # copy is charged the *default* copy's findings: findings that belong to
  # some other checkout, which this caller cannot see and must not answer
  # for. On the box this was found, promoting from a scope with no copy
  # read `devops-qa-b9`'s problems and refused a promotion that had nothing
  # to do with them.
  #
  # The gate has to resolve the copy it is judging, and with none there is
  # nothing to judge: refuse, naming what is missing, rather than silently
  # judging a copy the caller never mentioned.
  describe "a scope with no working copy" do
    test "is refused, naming the missing copy", %{scope: scope} do
      scopeless = %{scope | active_working_copy_id: nil}

      assert {:error, %{reason: reason}} = Promotion.gate(scopeless, @head),
             "the gate judged a copy the caller never named. With no working copy " <>
               "on the scope there is nothing to gate, so this has to refuse " <>
               "rather than fall back to some other checkout's problems."

      assert reason =~ "working copy" or reason =~ "checkout",
             "the refusal does not say what is missing, so an agent that has " <>
               "one scope shape and needs another cannot tell what to change. " <>
               "Got:\n#{reason}"
    end

    test "is not charged another copy's problems", %{scope: scope} do
      # Another checkout's blocking finding, which the fallback reads because
      # `default_id/1` is a pure function of the project id. The scopeless
      # caller must not be refused over it: it is not this caller's copy and
      # `named_copy/1` would name a copy that is not the caller's either.
      theirs =
        issue_scope(scope, "a checkout the caller never named")

      problem_fixture(%{theirs.scope | active_working_copy_id: theirs.id}, %{
        source: "compiler",
        source_type: :static_analysis,
        severity: :warning,
        message: "a warning that belongs to the other checkout",
        category: "warning",
        rule: nil
      })

      scopeless = %{scope | active_working_copy_id: nil}

      assert {:error, %{reason: reason}} = Promotion.gate(scopeless, @head),
             "a promotion with no working copy on its scope was judged anyway."

      refute reason =~ "a warning that belongs to the other checkout",
             "the refusal is reading another checkout's problems. That is the " <>
               "`02796b61` bug: a caller is refused over findings on a copy it " <>
               "never named and cannot fix.\n\nGot:\n#{reason}"
    end
  end
end
