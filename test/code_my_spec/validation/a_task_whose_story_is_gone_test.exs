defmodule CodeMySpec.Validation.ATaskWhoseStoryIsGoneTest do
  @moduledoc """
  A task pointing at a deleted story is cancelled, not failed on forever.

  Issue `3d7ae872`. Story 880 was deleted on purpose — its premise,
  `CodeMySpecWeb.ChatLive`, had been deleted from the codebase too — and left an
  open `bdd_specs_exist` task behind. From then on every stop failed with
  `{:story_not_found, …}`, so the agent got no verdict at all, about work that
  had nothing to do with the story in question.

  `TaskEvaluator` already knew what to do with an orphan: `{:error,
  :entity_missing}` cancels the task and lets the session pull a fresh one. What
  it did not recognise was the same orphan said in words — `WriteBddSpecs`
  answers `{:story_not_found, message}`, with a message written for an agent
  that typed a bad id, and that fell through to the generic error clause that
  blocks.

  The message's other possibility — "you're scoped to the wrong project" — is
  why cancelling has to be argued rather than assumed. The scope doing the
  evaluating is the task's own session's scope, so it is the project the task was
  created under: wrong-project is something an agent can do by hand and not
  something a stop hook can do by accident.
  """

  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.SessionsFixtures
  import CodeMySpec.UsersFixtures

  alias CodeMySpec.AgentTasks.WriteBddSpecs
  alias CodeMySpec.Sessions
  alias CodeMySpec.Validation.TaskEvaluator

  # A number no story on this project has. `Sessions.Task.story_id` is the
  # durable story *number*, not the row id.
  @deleted_story 999_999

  setup do
    scope = full_scope_fixture()
    session = session_fixture(scope, %{type: WriteBddSpecs})

    %{scope: scope, session: session}
  end

  defp a_task_for(scope, session, story_id) do
    {:ok, session} =
      Sessions.prepare_task(scope, session, %{
        requirement_name: "bdd_specs_exist",
        session_type: WriteBddSpecs,
        story_id: story_id
      })

    task = List.last(session.tasks)
    {:ok, session} = Sessions.activate_task(scope, session, task.id)

    {session, Enum.find(session.tasks, &(&1.id == task.id))}
  end

  test "the stop is not held hostage by it", %{scope: scope, session: session} do
    {session, task} = a_task_for(scope, session, @deleted_story)

    assert {:ok, :valid} = TaskEvaluator.evaluate_task(scope, session, task),
           """
           The evaluator failed on a task it can never evaluate. Every stop from
           here gets that failure instead of a verdict on the work actually
           done, and nothing the agent can edit will change it.
           """
  end

  test "and the task is cancelled rather than left to do it again", %{
    scope: scope,
    session: session
  } do
    {session, task} = a_task_for(scope, session, @deleted_story)

    {:ok, :valid} = TaskEvaluator.evaluate_task(scope, session, task)

    reread = Sessions.get_session(scope, session.id)
    cancelled = Enum.find(reread.tasks, &(&1.id == task.id))

    assert cancelled.status == :cancelled, """
    Answering the stop without clearing the task leaves it active, so the next
    stop meets the same orphan and the session never pulls fresh work.
    """
  end
end
