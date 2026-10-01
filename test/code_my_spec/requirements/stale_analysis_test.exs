defmodule CodeMySpec.Requirements.StaleAnalysisTest do
  @moduledoc """
  What a requirement backed by an analyzer says when the run behind it is
  behind the code.

  The latest completed run answers, however old (28d72f8a). Analysis and
  requirements are orthogonal: a run that predates an edit neither withholds a
  clean verdict nor relabels a failure — whether results are current is the
  promote gate's question, keyed on the commit.

  What still withholds is absence. With no completed spex run on this working
  copy nothing has been recorded, and a clean verdict from nothing is not a
  pass. `bdd_specs_passing` is the one requirement this applies to, through
  `RequirementGraph.serve/2`, which every reader goes through.
  """

  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.{AnalysisFixtures, ProblemsFixtures, StoriesFixtures, UsersFixtures}

  alias CodeMySpec.Requirements.Preloader
  alias CodeMySpec.Requirements.RequirementGraph
  alias CodeMySpec.Requirements.SpecsPassingChecker

  setup do
    scope = full_scope_fixture()
    story = story_fixture(scope, %{title: "Unlatched"})
    path = "test/spex/#{story.id}_feature/criterion_1_spex.exs"

    {_n, _} =
      CodeMySpec.Files.upsert_files(scope, [
        %{path: path, role: :bdd_spec, story_id: story.id, valid: true, mtime: DateTime.utc_now()}
      ])

    %{scope: scope, story: story, path: path}
  end

  # Computed the way the graph computes it — from the problems alone — then
  # served, which is what a reader receives.
  defp served(scope, story) do
    {:ok, ctx} = Preloader.load(scope)
    {satisfied, details} = SpecsPassingChecker.passing?(scope, story, ctx)

    [node] =
      RequirementGraph.serve(
        [%{name: "bdd_specs_passing", satisfied: satisfied, details: details}],
        ctx
      )

    {node.satisfied, node.details}
  end

  defp edit_files(scope) do
    {_n, _} =
      CodeMySpec.Files.upsert_files(scope, [
        %{
          path: "lib/edited_after.ex",
          role: :implementation,
          valid: true,
          mtime: DateTime.utc_now()
        }
      ])
  end

  test "with no completed spex run, a clean verdict is withheld", %{scope: scope, story: story} do
    assert {false, %{reason: reason}} = served(scope, story)
    assert reason =~ "No spex run has completed"
  end

  test "a completed run with the story's specs green passes", %{scope: scope, story: story} do
    fresh_analysis_runs_fixture(scope, ["spex"])

    assert {true, _details} = served(scope, story)
  end

  test "a green run that predates an edit still answers", %{scope: scope, story: story} do
    fresh_analysis_runs_fixture(scope, ["spex"])
    edit_files(scope)

    assert {true, _details} = served(scope, story),
           "the latest completed run answers however old — whether it saw the " <>
             "current code is the promote gate's question, not the graph's"
  end

  test "a red run that predates an edit is served as it stands, with no stale label",
       %{scope: scope, story: story, path: path} do
    fresh_analysis_runs_fixture(scope, ["spex"])

    problem_fixture(scope, %{
      source: "spex",
      source_type: :test,
      file_path: path,
      severity: :error,
      category: "spex"
    })

    edit_files(scope)

    assert {false, details} = served(scope, story)
    assert details.reason =~ "fail on the latest spex run"
    refute Map.has_key?(details, :stale)
  end
end
