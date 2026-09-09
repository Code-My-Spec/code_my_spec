defmodule CodeMySpec.Validation.AnotherCopysStoryIsNotThisAgentsProblemTest do
  @moduledoc """
  A finding about a story assigned elsewhere is not this checkout's work.

  Spec files live on disk and stories are assigned, and the two drift: a copy
  that once held an epic keeps its files after the epic moves. The analyzer
  sweeps the tree it is given, so those specs are still swept and still reported
  against the copy they sit in.

  Measured on Broken Oaths 2026-09-09: a coding agent on the war-epic copy was
  shown 21 problems, every one of them story 45 of "Diplomacy and Alliances", an
  epic assigned to the main checkout. It read them and stopped — "the 20 listed
  problems remain the same pre-existing, unrelated stories" — which is the
  correct reading, and left it with nothing to do while its own epic was done.

  This is `issues_resolved`'s rule applied to problems: a gate whose passing
  state depends on work outside the gated unit is a wall.
  """
  use CodeMySpecTest.DataCase, async: true

  alias CodeMySpec.Validation

  import CodeMySpec.DevicesFixtures
  import CodeMySpec.ProblemsFixtures
  import CodeMySpec.StoriesFixtures
  import CodeMySpec.UsersFixtures

  setup do
    scope = full_scope_fixture()
    %{scope: scope}
  end

  # Real rows: `stories.working_copy_id` is a foreign key, so a generated uuid
  # is not a copy this story could have been assigned to.
  defp a_copy(scope, label) do
    {:ok, copy} = CodeMySpec.WorkingCopies.issue(scope, nil, label: label, device: device_fixture(scope))
    copy.id
  end

  defp red_spec(scope, story) do
    path = "test/spex/#{story.id}_a_feature/criterion_1_spex.exs"

    {_n, _} =
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

  defp ready_story(scope, attrs) do
    story = story_fixture(scope, attrs)
    {:ok, story} = CodeMySpec.Stories.set_specs_ready(scope, story, true)
    story
  end

  test "a story assigned to another copy does not gate this one", %{scope: scope} do
    elsewhere = a_copy(scope, "somebody else's checkout")
    here = %{scope | active_working_copy_id: a_copy(scope, "this checkout")}
    story = ready_story(scope, %{title: "Another Copy's Story", working_copy_id: elsewhere})

    # Filed against *this* checkout, because that is the situation: the spec
    # file is sitting in this tree while the story belongs to another copy.
    red_spec(here, story)
    problems = CodeMySpec.Problems.list_project_problems(here, severity: :error)

    assert Validation.enforceable(here, problems) == [],
           "an agent cannot fix a story that belongs to a checkout it is not standing in"
  end

  test "a story assigned to this copy still gates it", %{scope: scope} do
    mine = a_copy(scope, "this checkout")
    here = %{scope | active_working_copy_id: mine}
    story = ready_story(scope, %{title: "My Story", working_copy_id: mine})
    red_spec(here, story)
    problems = CodeMySpec.Problems.list_project_problems(here, severity: :error)

    assert length(Validation.enforceable(here, problems)) == 1
  end

  # Nobody else owns it, and dropping it would let a finding belong to no one.
  test "an unassigned story still gates", %{scope: scope} do
    here = %{scope | active_working_copy_id: a_copy(scope, "this checkout")}
    story = ready_story(scope, %{title: "Unassigned"})
    red_spec(here, story)
    problems = CodeMySpec.Problems.list_project_problems(here, severity: :error)

    assert length(Validation.enforceable(here, problems)) == 1
  end
end
