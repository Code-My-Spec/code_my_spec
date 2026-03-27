defmodule CodeMySpec.McpServers.Tasks.Tools.StartTaskTest do
  use ExUnit.Case, async: true

  import CodeMySpec.ComponentsFixtures
  import CodeMySpec.RequirementsFixtures
  import CodeMySpec.SessionsFixtures
  import CodeMySpec.UsersFixtures

  alias Anubis.Server.Frame
  alias Anubis.Server.Response
  alias CodeMySpec.McpServers.Tasks.Tools.StartTask
  alias CodeMySpec.Sessions

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(CodeMySpec.Repo)
  end

  describe "execute/2" do
    test "activates a prepared task and returns the prompt" do
      {scope, session, task} = setup_prepared_task()
      frame = %Frame{assigns: %{current_scope: scope}}

      assert {:reply, response, ^frame} =
               StartTask.execute(
                 %{session_id: session.id, task_id: task.id},
                 frame
               )

      assert response.isError != true
      content = response_text(response)
      # Should contain prompt content from the task module
      assert is_binary(content) and content != ""
    end

    test "assigns agent_id when provided" do
      {scope, session, task} = setup_prepared_task()
      frame = %Frame{assigns: %{current_scope: scope}}

      assert {:reply, response, ^frame} =
               StartTask.execute(
                 %{session_id: session.id, task_id: task.id, agent_id: "agent-123"},
                 frame
               )

      assert response.isError != true

      # Verify agent was assigned
      updated_session = Sessions.get_session(scope, session.id)
      updated_task = Enum.find(updated_session.tasks, &(&1.id == task.id))
      assert updated_task.agent_id == "agent-123"
    end

    test "returns prompt again for already active task" do
      {scope, session, task} = setup_prepared_task()
      frame = %Frame{assigns: %{current_scope: scope}}

      # Activate the task first
      {:ok, _} = Sessions.activate_task(scope, session, task.id, nil)

      assert {:reply, response, ^frame} =
               StartTask.execute(
                 %{session_id: session.id, task_id: task.id},
                 frame
               )

      assert response.isError != true
    end

    test "returns error for completed task" do
      {scope, session, task} = setup_prepared_task()
      frame = %Frame{assigns: %{current_scope: scope}}

      {:ok, _} = Sessions.activate_task(scope, session, task.id, nil)
      {:ok, _} = Sessions.complete_task(scope, session, task.id, :completed)

      assert {:reply, response, ^frame} =
               StartTask.execute(
                 %{session_id: session.id, task_id: task.id},
                 frame
               )

      assert response.isError == true
      assert response_text(response) =~ "cannot start"
    end

    test "returns error for non-existent session" do
      scope = full_scope_fixture()
      frame = %Frame{assigns: %{current_scope: scope}}

      assert {:reply, response, ^frame} =
               StartTask.execute(
                 %{session_id: Ecto.UUID.generate(), task_id: Ecto.UUID.generate()},
                 frame
               )

      assert response.isError == true
      assert response_text(response) =~ "Session not found"
    end

    test "returns error for non-existent task" do
      scope = full_scope_fixture()
      session = session_fixture(scope)
      frame = %Frame{assigns: %{current_scope: scope}}

      assert {:reply, response, ^frame} =
               StartTask.execute(
                 %{session_id: session.id, task_id: Ecto.UUID.generate()},
                 frame
               )

      assert response.isError == true
      assert response_text(response) =~ "Task not found"
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp setup_prepared_task do
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

    {:ok, updated_session} = Sessions.prepare_task(scope, session, task_attrs)

    task =
      updated_session.tasks
      |> Enum.find(&(&1.requirement_name == requirement.name and &1.status == :prepared))

    {scope, updated_session, task}
  end

  defp response_text(response) do
    protocol = Response.to_protocol(response)
    hd(protocol["content"])["text"]
  end
end
