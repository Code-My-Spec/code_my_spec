defmodule CodeMySpec.Requirements.ArchitectureReadsNoDatabaseTest do
  @moduledoc """
  The architecture verdict is answered from the facts handed in.

  A harness checks its own files and has no database. Handed the checkout's
  files, whether a component is authored, and the project's active story
  numbers and context names, `architecture_planned` answers what the database
  path answers, a stale proposal included.
  """
  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.ComponentsFixtures
  import CodeMySpec.StoriesFixtures
  import CodeMySpec.UsersFixtures

  alias CodeMySpec.{Components, Paths, Repo, Stories}
  alias CodeMySpec.Files.File, as: FileRecord
  alias CodeMySpec.Requirements.ArchitectureChecker
  alias CodeMySpecTest.WithoutDatabase

  test "the verdict from the facts handed in, with no database, is the verdict from the database" do
    scope = full_scope_fixture()
    story = story_fixture(scope)
    context = component_fixture(scope, %{type: "context"})

    proposal =
      Repo.insert!(%FileRecord{
        project_id: scope.active_project_id,
        working_copy_id: scope.active_working_copy_id,
        path: Paths.proposal_path(),
        role: :architecture,
        valid: true,
        validation_errors: %{
          "data" => %{
            "story_numbers" => [story.number, 9_999],
            "context_names" => [context.module_name, "Gone.Context"]
          }
        }
      })

    from_database = ArchitectureChecker.complete?(scope, nil)
    {false, %{reason: reason}} = from_database
    assert reason =~ "out of date", "the premise did not hold: the proposal is not stale"

    {:ok, stories} = Stories.list_project_stories(scope)

    handed = %{
      files_by_project: [proposal],
      authored?: Components.any_authored?(scope),
      story_numbers: Enum.map(stories, & &1.number),
      context_names: scope |> Components.list_contexts() |> Enum.map(& &1.module_name)
    }

    assert WithoutDatabase.run(fn -> ArchitectureChecker.complete?(scope, nil, handed) end) ==
             {:ok, from_database}
  end
end
