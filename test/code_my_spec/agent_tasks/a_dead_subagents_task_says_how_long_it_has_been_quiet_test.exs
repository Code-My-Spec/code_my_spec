defmodule CodeMySpec.AgentTasks.ADeadSubagentsTaskSaysHowLongItHasBeenQuietTest do
  @moduledoc """
  733ac788: a sub-agent that has stopped heartbeating and one that is merely
  slow both read as "owned by sub-agent ..., which has not submitted yet" --
  identical text for a dead QA pass and a healthy one, to whoever is waiting
  on it. `QaStory.evaluate/2`'s skip feedback now says how long that
  sub-agent has gone unheard from, using the heartbeat `register_subagent`
  already records (Story 704), rather than only that it exists.
  """

  use ExUnit.Case, async: true

  import CodeMySpec.StoriesFixtures
  import CodeMySpec.UsersFixtures

  alias CodeMySpec.AgentTasks.QaStory
  alias CodeMySpec.Repo
  alias CodeMySpec.Sessions
  alias Ecto.Adapters.SQL.Sandbox

  setup do
    :ok = Sandbox.checkout(Repo)
  end

  setup do
    scope = full_scope_fixture()
    session = CodeMySpec.SessionsFixtures.session_fixture(scope)
    story = story_fixture(scope)
    agent_id = Ecto.UUID.generate()

    task_attrs = %{
      session_type: QaStory,
      requirement_name: "qa_complete",
      project_id: scope.active_project_id,
      story_id: story.id
    }

    {:ok, prepared} = Sessions.prepare_task(scope, session, task_attrs)
    prepared_task = Enum.find(prepared.tasks, &(&1.status == :prepared))
    {:ok, active} = Sessions.activate_task(scope, prepared, prepared_task.id, agent_id)
    task = Enum.find(active.tasks, &(&1.id == prepared_task.id))

    %{scope: scope, session: active, task: task, agent_id: agent_id}
  end

  test "no registration at all reads as that, not as silence", %{scope: scope, task: task} do
    assert {:ok, :skip, feedback} = QaStory.evaluate(scope, task)

    assert feedback =~ "no active session has a registration for it", """
    A sub-agent that never registered (or whose session is no longer active)
    must read differently from one that registered and went quiet -- the
    first is not evidence of a crash, the second is.
    """
  end

  test "a recent heartbeat reads as recent, not stale", %{
    scope: scope,
    session: session,
    task: task,
    agent_id: agent_id
  } do
    {:ok, _} =
      Sessions.register_subagent(scope, session, %{
        agent_id: agent_id,
        agent_name: "aqa-test",
        last_heartbeat_at: DateTime.add(DateTime.utc_now(), -60, :second)
      })

    assert {:ok, :skip, feedback} = QaStory.evaluate(scope, task)
    assert feedback =~ "last heard from"
    refute feedback =~ "TTL"
  end

  test "a heartbeat past the configured TTL names the TTL it is past", %{
    scope: scope,
    session: session,
    task: task,
    agent_id: agent_id
  } do
    {:ok, _} =
      Sessions.register_subagent(scope, session, %{
        agent_id: agent_id,
        agent_name: "aqa-test",
        last_heartbeat_at: DateTime.add(DateTime.utc_now(), -15 * 60, :second)
      })

    assert {:ok, :skip, feedback} = QaStory.evaluate(scope, task)

    assert feedback =~ "past its 10-minute TTL", """
    The whole point is distinguishing a stale claim from a live one -- this
    is the signal a parent that has waited an hour should have instead of a
    file mtime.
    """
  end
end
