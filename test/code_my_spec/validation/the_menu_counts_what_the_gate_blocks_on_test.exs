defmodule CodeMySpec.Validation.TheMenuCountsWhatTheGateBlocksOnTest do
  @moduledoc """
  The problems the menu advertises are the problems the gate would enforce.

  `Validation.enforceable/2` is public for this reason and says so: "two copies
  of what counts as enforceable drift, and the drift is silent." The menu was
  the third copy, and it drifted furthest — it counted every recorded error in
  the project.

  The gap has a shape. A spex failure on a story that has not reached
  `bdd_specs_passing` is the red bar that drives the implementation;
  `split_by_story_enforcement/3` holds it back from the gate for exactly that
  reason. The menu counted it anyway, and ranked the total above the agent's own
  requirements. Broken Oaths on 2026-09-08 opened every coding stop with "133
  problems in this working copy" over a backlog of 127 unwritten features across
  ten stories — none of it the agent's work, none of it blocking anything. It
  read the list, found nothing of its own, and stopped. Every time.

  John: "those specs should not be contributing to the problems yet because the
  development's not done."
  """
  use CodeMySpecTest.DataCase, async: true

  alias CodeMySpec.Agents.Menu
  alias CodeMySpec.Problems
  alias CodeMySpec.Validation

  import CodeMySpec.ProblemsFixtures
  import CodeMySpec.StoriesFixtures
  import CodeMySpec.UsersFixtures

  setup do
    %{scope: full_scope_fixture()}
  end

  defp red_spec_for(scope, story) do
    [criterion | _] = story.criteria
    path = CodeMySpec.BddSpecs.spec_file_path(story, criterion)

    {_n, _} =
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
  end

  defp problem_count(scope) do
    scope
    |> Menu.live(:coding, nil)
    |> Keyword.get(:problems, 0)
  end

  # Every red spex blocks (John, 2026-10-05), so the menu advertises it.
  test "a red spec is advertised, whatever its story's state", %{scope: scope} do
    story = story_fixture(scope, %{title: "Not Built Yet"})
    red_spec_for(scope, story)

    problems = Problems.list_project_problems(scope, severity: :error)

    assert length(Validation.enforceable(scope, problems)) == 1
    assert problem_count(scope) == 1
  end
end
