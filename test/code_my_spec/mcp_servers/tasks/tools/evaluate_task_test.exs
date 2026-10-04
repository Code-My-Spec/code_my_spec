defmodule CodeMySpec.McpServers.Tasks.Tools.EvaluateTaskTest do
  use ExUnit.Case, async: true

  import CodeMySpec.ComponentsFixtures
  import CodeMySpec.IssuesFixtures
  import CodeMySpec.SessionsFixtures
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

  describe "execute/2 — terminal state" do
    test "returns already-terminal for completed task" do
      {scope, session, task} = setup_active_task()
      frame = %Frame{assigns: %{current_scope: scope}}

      {:ok, _} = Sessions.complete_task(scope, session, task.id, :completed)

      assert {:reply, response, ^frame} =
               EvaluateTask.execute(%{task_id: task.id, session_id: session.id}, frame)

      refute response.isError
      content = response_text(response)
      assert content =~ "already completed"
      assert content =~ "get_next_requirement"
    end
  end

  describe "execute/2 — session resolution" do
    test "resolves session by DB UUID" do
      {scope, session, task} = setup_active_task()
      frame = %Frame{assigns: %{current_scope: scope}}

      {:ok, _} = Sessions.complete_task(scope, session, task.id, :completed)

      assert {:reply, response, ^frame} =
               EvaluateTask.execute(%{task_id: task.id, session_id: session.id}, frame)

      refute response.isError
    end

    test "resolves session by external_conversation_id" do
      scope = full_scope_fixture()
      component = component_fixture(scope)
      frame = %Frame{assigns: %{current_scope: scope}}

      external_id = "ext-eval-#{System.unique_integer([:positive])}"
      {:ok, ext_session} = Sessions.find_or_create_session(scope, external_id)

      task_attrs = %{
        session_type: CodeMySpec.AgentTasks.ComponentCode,
        requirement_name: "implementation_file",
        project_id: scope.active_project_id,
        component_id: component.id
      }

      {:ok, session_with_task} = Sessions.prepare_task(scope, ext_session, task_attrs)
      task = Enum.find(session_with_task.tasks, &(&1.status == :prepared))
      {:ok, active_session} = Sessions.activate_task(scope, session_with_task, task.id, nil)
      {:ok, _} = Sessions.complete_task(scope, active_session, task.id, :completed)

      # Use external_id instead of DB UUID
      assert {:reply, response, ^frame} =
               EvaluateTask.execute(%{task_id: task.id, session_id: external_id}, frame)

      refute response.isError
      assert response_text(response) =~ "already completed"
    end
  end

  describe "execute/2 — IssueQa dispatches to its own evaluate/2" do
    test "an issue-bound qa_complete task is skipped, not routed through the generic calculator" do
      scope = full_scope_fixture()
      issue = issue_fixture(scope)
      frame = %Frame{assigns: %{current_scope: scope}}

      external_id = "ext-issue-qa-#{System.unique_integer([:positive])}"
      {:ok, ext_session} = Sessions.find_or_create_session(scope, external_id)

      task_attrs = %{
        session_type: CodeMySpec.AgentTasks.IssueQa,
        requirement_name: "qa_complete",
        project_id: scope.active_project_id,
        issue_id: issue.id
      }

      {:ok, session_with_task} = Sessions.prepare_task(scope, ext_session, task_attrs)
      task = Enum.find(session_with_task.tasks, &(&1.status == :prepared))
      {:ok, _active_session} = Sessions.activate_task(scope, session_with_task, task.id, nil)

      assert {:reply, response, ^frame} =
               EvaluateTask.execute(%{task_id: task.id, session_id: external_id}, frame)

      refute response.isError,
             "an issue-bound qa_complete task must dispatch to IssueQa.evaluate/2, not fall " <>
               "through to the generic Evaluator and fail looking up qa_complete as a " <>
               "project-level requirement"

      assert response_text(response) =~ "submit_issue_qa_result"
    end
  end

  describe "execute/2 — error paths" do
    test "returns error for non-existent session" do
      scope = full_scope_fixture()
      frame = %Frame{assigns: %{current_scope: scope}}

      assert {:reply, response, ^frame} =
               EvaluateTask.execute(
                 %{task_id: Ecto.UUID.generate(), session_id: Ecto.UUID.generate()},
                 frame
               )

      assert response.isError
      assert response_text(response) =~ "Session not found"
    end

    test "returns error for non-existent task" do
      scope = full_scope_fixture()
      session = session_fixture(scope)
      frame = %Frame{assigns: %{current_scope: scope}}

      assert {:reply, response, ^frame} =
               EvaluateTask.execute(
                 %{task_id: Ecto.UUID.generate(), session_id: session.id},
                 frame
               )

      assert response.isError
      assert response_text(response) =~ "Task not found"
    end

    test "returns error when session_id is missing" do
      scope = full_scope_fixture()
      frame = %Frame{assigns: %{current_scope: scope}}

      assert {:reply, response, ^frame} =
               EvaluateTask.execute(%{task_id: Ecto.UUID.generate()}, frame)

      assert response.isError
      assert response_text(response) =~ "No session_id"
    end

    test "returns error without valid scope" do
      frame = %Frame{assigns: %{}}

      assert {:reply, response, ^frame} =
               EvaluateTask.execute(%{task_id: "whatever", session_id: "anything"}, frame)

      assert response.isError
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp setup_active_task(task_module \\ CodeMySpec.AgentTasks.ComponentCode) do
    scope = full_scope_fixture()
    component = component_fixture(scope)
    session = session_fixture(scope)

    task_attrs = %{
      session_type: task_module,
      requirement_name: "implementation_file",
      project_id: scope.active_project_id,
      component_id: component.id,
      component_module_name: component.module_name
    }

    {:ok, session_with_task} = Sessions.prepare_task(scope, session, task_attrs)

    task =
      session_with_task.tasks
      |> Enum.find(&(&1.requirement_name == "implementation_file" and &1.status == :prepared))

    {:ok, active_session} = Sessions.activate_task(scope, session_with_task, task.id, nil)

    active_task =
      active_session.tasks
      |> Enum.find(&(&1.id == task.id))

    {scope, active_session, active_task}
  end

  defp response_text(response) do
    protocol = Response.to_protocol(response)
    hd(protocol["content"])["text"]
  end
end
