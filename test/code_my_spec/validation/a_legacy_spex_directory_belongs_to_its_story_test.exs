defmodule CodeMySpec.Validation.ALegacySpexDirectoryBelongsToItsStoryTest do
  @moduledoc """
  A spex failure with no recorded criterion is judged by the story that owns
  its directory.

  metric_flow, 2026-09-27: legacy directories carry no story number, and files
  named for renumbered criteria were recorded against nothing. Unattributed,
  their failures blocked every promote even though their stories were not
  `specs_ready` — the latch that exists so unbuilt spex do not.
  """

  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.ProblemsFixtures
  import CodeMySpec.StoriesFixtures
  import CodeMySpec.UsersFixtures

  alias CodeMySpec.Stories.AcceptanceCriteria
  alias CodeMySpec.Validation.Blocking

  @dir "test/spex/agency-white-label-configuration-781a555e"

  # A spex file the story's criterion names (`Files.SpecBinding`).
  defp recorded(scope, story, path) do
    {:ok, criterion} = AcceptanceCriteria.create_criterion(scope, story, %{description: "owned"})

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
  end

  defp red(scope, path) do
    problem_fixture(scope, %{
      source: "spex",
      source_type: :test,
      file_path: path,
      message: "feature not built",
      severity: :error,
      category: "spex"
    })

    CodeMySpec.Problems.list_project_problems(scope, severity: :error)
  end

  # Every red spex blocks (John, 2026-10-05), unbuilt story or not.
  test "an unrecorded file in a not-ready story's directory blocks too" do
    scope = full_scope_fixture()
    story = story_fixture(scope)
    recorded(scope, story, "#{@dir}/criterion_3901_owned_spex.exs")

    problems = red(scope, "#{@dir}/criterion_4152_renumbered_spex.exs")

    assert length(Blocking.enforceable(scope, problems)) == 1
  end

  test "a directory two stories record into answers nothing, so it still blocks" do
    scope = full_scope_fixture()
    recorded(scope, story_fixture(scope), "#{@dir}/criterion_3901_a_spex.exs")
    recorded(scope, story_fixture(scope), "#{@dir}/criterion_3902_b_spex.exs")

    problems = red(scope, "#{@dir}/criterion_4152_renumbered_spex.exs")

    assert length(Blocking.enforceable(scope, problems)) == 1
  end
end
