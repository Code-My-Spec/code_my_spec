defmodule CodeMySpec.AgentTasks.QaStoryWithoutADiskTest do
  @moduledoc """
  `qa_complete`'s prompt, on a server with no working copy.

  The QA drill reported `start_task` crashing for every story and worked from
  the playbook by hand instead — which produced the right result only because
  that agent knew to. One that trusts the tool is blocked on every story.

  The cause was `BddSpecs.list_specs_for_story/2`, which walks the working copy
  and has no clause for a nil environment. Only the spec *paths* were wanted,
  and those are already in the File records the scan produced.
  """

  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.UsersFixtures

  alias CodeMySpec.AgentTasks.QaStory
  alias CodeMySpec.Files.File, as: FileRecord

  setup do
    scope = full_scope_fixture()

    {:ok, story} =
      CodeMySpec.Stories.create_story(scope, %{
        title: "Capture a task",
        description: "As a user, I want to capture a task so that I do not lose it."
      })

    %{scope: %{scope | environment: nil, cwd: nil}, story: story}
  end

  test "renders a prompt rather than raising", %{scope: scope, story: story} do
    assert {:ok, prompt} = QaStory.command(scope, %{story_id: story.id})
    assert is_binary(prompt) and prompt != ""
  end

  test "names the story's spec files, read from the sync", %{scope: scope, story: story} do
    path = "test/spex/#{story.id}_capture_a_task/criterion_1_a_task_is_captured_spex.exs"

    Repo.insert!(%FileRecord{
      project_id: scope.active_project_id,
      working_copy_id: scope.active_working_copy_id,
      path: path,
      role: :bdd_spec,
      story_id: story.id,
      valid: true,
      validation_errors: %{}
    })

    assert {:ok, prompt} = QaStory.command(scope, %{story_id: story.id})

    assert prompt =~ path,
           "the QA agent is told which spex cover the story; that list comes " <>
             "from the sync, so it is available whether or not this machine " <>
             "holds the files"
  end
end
