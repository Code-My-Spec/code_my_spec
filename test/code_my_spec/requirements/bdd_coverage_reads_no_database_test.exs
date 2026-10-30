defmodule CodeMySpec.Requirements.BddCoverageReadsNoDatabaseTest do
  @moduledoc """
  A story's spec coverage is answered from the criteria and files handed in.

  A harness checks its own files and has no database, so `bdd_specs_exist`
  must come out of what it is given: the read model's criteria, retired ones
  and all, in whatever order. Handed the same facts, it answers what the
  database path answers.
  """
  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.AcceptanceCriteriaFixtures
  import CodeMySpec.StoriesFixtures
  import CodeMySpec.UsersFixtures

  alias CodeMySpec.Files.File, as: FileRecord
  alias CodeMySpec.Requirements.{Registry, RequirementCalculator}
  alias CodeMySpec.Stories.AcceptanceCriteria
  alias CodeMySpecTest.WithoutDatabase

  test "coverage from the criteria handed in, with no database, is coverage from the database" do
    scope = full_scope_fixture()
    story = story_fixture(scope, %{ready_for_dev: true})
    first = criterion_fixture(scope, story)
    criterion_fixture(scope, story)
    {:ok, _} = AcceptanceCriteria.retire_criterion(scope, criterion_fixture(scope, story))

    files = [
      %FileRecord{
        path: "test/spex/a_spex.exs",
        role: :bdd_spec,
        valid: true,
        criterion_number: first.number
      }
    ]

    definition = Enum.find(Registry.get_story_requirements(), &(&1.name == "bdd_specs_exist"))

    from_database =
      RequirementCalculator.compute_one(scope, story, definition, files, %{
        files_by_project: files
      })

    refute from_database.satisfied, "the premise did not hold: one criterion is uncovered"

    handed = %{
      files_by_project: files,
      criteria_by_story: %{
        story.id => Enum.shuffle(AcceptanceCriteria.list_all_story_criteria(scope, story.id))
      }
    }

    assert WithoutDatabase.run(fn ->
             RequirementCalculator.compute_one(scope, story, definition, files, handed)
           end) == {:ok, from_database}
  end
end
