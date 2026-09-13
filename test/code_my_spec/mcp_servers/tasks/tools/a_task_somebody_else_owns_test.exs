defmodule CodeMySpec.McpServers.Tasks.Tools.ATaskSomebodyElseOwnsTest do
  @moduledoc """
  Asking to evaluate a task a sub-agent owns is answered, not crashed.

  Issue `229a42e7`. `QaStory.evaluate/2` has a third outcome beside pass and
  needs-work: `{:ok, :skip, why}`, for a task a sub-agent holds and has not
  submitted for yet. It exists because returning `:valid` there completed the
  sub-agent's task out from under it before any attempt existed (`7f79b855`).

  `TaskEvaluator` — the stop hook's path — has had a clause for it since. This
  surface did not, so the tuple fell through a `case` and raised
  `CaseClauseError`, which reaches the caller as a bare `-32603 Internal
  error` with nothing in it. The reporter retried three times and checked the
  server was up in between, which is exactly what that message invites.
  """

  use ExUnit.Case, async: true

  import CodeMySpec.StoriesFixtures
  import CodeMySpec.UsersFixtures

  alias Anubis.Server.Frame
  alias Anubis.Server.Response
  alias CodeMySpec.McpServers.Tasks.Tools.EvaluateTask
  alias CodeMySpec.Repo
  alias CodeMySpec.Sessions
  alias Ecto.Adapters.SQL.Sandbox

  setup do
    :ok = Sandbox.checkout(Repo)
  end

  test "it says whose it is, and leaves it open" do
    {scope, session, task} = a_qa_task_owned_by_a_subagent()
    frame = %Frame{assigns: %{current_scope: scope}}

    assert {:reply, response, ^frame} =
             EvaluateTask.execute(%{task_id: task.id, session_id: session.id}, frame)

    refute response.isError, """
    The caller asked about a task that is not theirs to close. Nothing went
    wrong, so this is not an error — and reporting one is what got it retried.
    """

    text = response_text(response)

    assert text =~ "sub-agent", """
    The reply does not say why the task was left alone, so the caller has no way
    to tell "not yours" from "something broke".
    """

    assert text =~ "wait", "nothing tells the caller that retrying answers the same thing"
  end

  test "and the task is still active afterwards" do
    {scope, session, task} = a_qa_task_owned_by_a_subagent()
    frame = %Frame{assigns: %{current_scope: scope}}

    EvaluateTask.execute(%{task_id: task.id, session_id: session.id}, frame)

    # Tasks are embedded in the session, so the session is what reloads.
    reloaded =
      scope
      |> Sessions.get_session(session.id)
      |> Map.fetch!(:tasks)
      |> Enum.find(&(&1.id == task.id))

    assert reloaded.status == :active, """
    Evaluating completed the sub-agent's task out from under it — 7f79b855
    again, from the manual surface this time rather than the stop hook.
    """
  end

  # `agent_id` on the task is what `QaStory.subagent_owns?/1` reads, and a
  # `qa_complete` task with no submitted attempt is the state it guards.
  defp a_qa_task_owned_by_a_subagent do
    scope = full_scope_fixture()
    session = CodeMySpec.SessionsFixtures.session_fixture(scope)
    story = story_fixture(scope)

    task_attrs = %{
      session_type: CodeMySpec.AgentTasks.QaStory,
      requirement_name: "qa_complete",
      project_id: scope.active_project_id,
      story_id: story.id
    }

    {:ok, prepared} = Sessions.prepare_task(scope, session, task_attrs)
    task = Enum.find(prepared.tasks, &(&1.status == :prepared))

    agent_id = Ecto.UUID.generate()
    {:ok, active} = Sessions.activate_task(scope, prepared, task.id, agent_id)

    {scope, active, Enum.find(active.tasks, &(&1.id == task.id))}
  end

  defp response_text(response) do
    protocol = Response.to_protocol(response)
    hd(protocol["content"])["text"]
  end
end
