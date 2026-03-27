defmodule CodeMySpec.McpServers.Tasks.Tools.EvaluateTaskTest do
  use ExUnit.Case, async: true

  import CodeMySpec.ComponentsFixtures
  import CodeMySpec.RequirementsFixtures
  import CodeMySpec.SessionsFixtures
  import CodeMySpec.UsersFixtures

  alias Anubis.Server.Frame
  alias Anubis.Server.Response
  alias CodeMySpec.McpServers.Tasks.Tools.EvaluateTask
  alias CodeMySpec.Sessions

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(CodeMySpec.Repo)
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

      requirement =
        requirement_fixture(scope, component, %{
          name: "test_spec",
          satisfied: false,
          satisfied_by: CodeMySpec.AgentTasks.ContextSpec
        })

      task_attrs = %{
        session_type: requirement.satisfied_by,
        requirement_id: requirement.id,
        requirement_name: requirement.name,
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

  defp setup_active_task do
    scope = full_scope_fixture()
    component = component_fixture(scope)
    session = session_fixture(scope)

    requirement =
      requirement_fixture(scope, component, %{
        name: "test_spec",
        satisfied: false,
        satisfied_by: CodeMySpec.AgentTasks.ContextSpec
      })

    task_attrs = %{
      session_type: requirement.satisfied_by,
      requirement_id: requirement.id,
      requirement_name: requirement.name,
      project_id: scope.active_project_id,
      component_id: component.id,
      component_module_name: component.module_name
    }

    {:ok, session_with_task} = Sessions.prepare_task(scope, session, task_attrs)

    task =
      session_with_task.tasks
      |> Enum.find(&(&1.requirement_name == requirement.name and &1.status == :prepared))

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
