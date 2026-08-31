defmodule CodeMySpec.AgentTasks.WriteBddSpecsScopingTest do
  @moduledoc """
  A spec written in the checkout the agent is working in counts.

  Most work happens in a worktree. The agent writes the spec file there, the
  harness scans that root and records it, and `bdd_specs_exist` asks whether the
  file exists — so it must ask about the checkout the request named, not about
  some other one.

  Getting this wrong does not look like a scoping bug. It looks like "Spec file
  not found" for a file the agent can see on its own disk, and it clears the
  moment the work is committed, pushed, and pulled into the other checkout — so
  the requirement silently gates on *have you pushed* rather than on *have you
  written the spec*. That cost a long diagnosis on story 967, where the same six
  specs were reported missing and then passed with no change to any of them.

  Both directions are pinned. A file recorded only for the working copy the
  request names has to satisfy the check, and a file recorded only for a
  *different* copy must not — otherwise one agent's worktree would satisfy
  another's requirement.
  """

  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.DevicesFixtures

  import CodeMySpec.AccountsFixtures
  import CodeMySpec.UsersFixtures
  import CodeMySpec.ProjectsFixtures
  import CodeMySpec.StoriesFixtures

  alias CodeMySpec.AgentTasks.WriteBddSpecs
  alias CodeMySpec.BddSpecs
  alias CodeMySpec.Files
  alias CodeMySpec.WorkingCopies

  setup do
    user = user_fixture()
    account = account_with_owner_fixture(user, %{name: "Scoping #{System.unique_integer()}"})
    scope = user_scope_fixture(user, account)
    project = project_fixture(scope, %{name: "Scoping project"})
    scope = %{scope | active_project_id: project.id, active_project: project}

    story = story_fixture(scope, %{title: "A story with criteria"})

    # Re-read, because `evaluate/2` does. Attaching criteria to the struct here
    # would be describing a story the checker never sees — it resolves the story
    # by id and gets whatever the fixture actually created.
    story = CodeMySpec.Stories.get_story(scope, story.id)

    assert story.criteria != [],
           "the fixture made a story with no criteria, so this test would pass without " <>
             "checking anything"

    {:ok, mine} = WorkingCopies.issue(scope, nil, label: "mine", device: device_fixture(scope))

    {:ok, theirs} =
      WorkingCopies.issue(scope, nil, label: "theirs", device: device_fixture(scope))

    paths = Enum.map(story.criteria, &BddSpecs.spec_file_path(story, &1))

    %{scope: scope, story: story, paths: paths, mine: mine, theirs: theirs}
  end

  # The writer names its working copy through the scope, which is the same way
  # the harness's reconcile does it.
  defp record(scope, working_copy, paths) do
    %{scope | active_working_copy_id: working_copy.id}
    |> Files.upsert_files(
      Enum.map(paths, fn path ->
        %{path: path, role: :bdd_spec, valid: true, mtime: DateTime.utc_now(), size: 1}
      end)
    )
  end

  test "a spec recorded for the working copy the request names counts", ctx do
    record(ctx.scope, ctx.mine, ctx.paths)

    scope = %{ctx.scope | active_working_copy_id: ctx.mine.id}

    assert {:ok, :valid} = WriteBddSpecs.evaluate(scope, %{story_id: ctx.story.id}),
           "the spec is recorded for the checkout this request names and was still " <>
             "reported missing. That is the failure that makes this requirement gate on " <>
             "having pushed rather than on having written the spec."
  end

  test "a spec recorded in another checkout of the same project also counts", ctx do
    record(ctx.scope, ctx.theirs, ctx.paths)

    scope = %{ctx.scope | active_working_copy_id: ctx.mine.id}

    assert {:ok, :valid} = WriteBddSpecs.evaluate(scope, %{story_id: ctx.story.id}),
           "a spec written in a sibling checkout of this project was treated as missing. " <>
             "That is what made this requirement gate on having pushed: the file exists, " <>
             "the story has it, and which copy the request came from is not part of the " <>
             "question."
  end

  test "a project with no spec recorded anywhere is still refused, and says where it looked",
       ctx do
    assert {:ok, :invalid, message} = WriteBddSpecs.evaluate(ctx.scope, %{story_id: ctx.story.id}),
           "a story with no spec file recorded in any checkout passed. Widening the lookup " <>
             "to the project must not widen it to everything."

    assert message =~ "Looked in:",
           "the refusal does not say where it looked, which is what let one sentence " <>
             "cover three unrelated defects"
  end
end
