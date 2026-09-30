defmodule CodeMySpec.Promotion.TheGateHoldsEverythingButUnlatchedSpexTest do
  @moduledoc """
  Zero problems on the promoting copy, except the red spex of stories that are
  not latched (30fd997f, John 2026-09-30).

  Compiler, credo and exunit findings refuse at :error or :warning; :info is advisory. A red spex of a
  story whose `specs_ready` is false merges — spex are committed before their
  code. A red spex of a latched story is a regression and refuses.

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

  defp red_spec(scope, story) do
    path = "test/spex/#{story.id}_a_feature/criterion_1_spex.exs"

    CodeMySpec.Files.upsert_files(scope, [
      %{path: path, role: :bdd_spec, story_id: story.id, valid: true, mtime: DateTime.utc_now()}
    ])

    problem_fixture(scope, %{
      source: "spex",
      source_type: :test,
      file_path: path,
      message: "no match of right hand side value: []",
      severity: :error,
      category: "spex"
    })
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
    assert reason =~ "not latched", "the refusal has to say what may stay red. Got: #{reason}"
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

  test "a red spex of a story that is not latched does not refuse", %{scope: scope} do
    story = story_fixture(scope, %{title: "Written Ahead Of Its Code"})
    red_spec(scope, story)

    assert {:ok, _certified} = Promotion.gate(scope, @head),
           "spex are committed before their code; an unlatched story's red spex must merge"
  end

  test "a red spex of a latched story refuses", %{scope: scope} do
    story = story_fixture(scope, %{title: "Proven Behaviour"})
    {:ok, story} = CodeMySpec.Stories.set_specs_ready(scope, story, true)
    red_spec(scope, story)

    assert {:error, %{reason: reason}} = Promotion.gate(scope, @head)
    assert reason =~ "1 spex"
    assert reason =~ "criterion_1_spex.exs"
  end
end
