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

  describe "execute/2 — happy path" do
    test "creates an active task and returns a prompt with Data JSON" do
      {scope, session, requirement} = setup_requirement()
      frame = %Frame{assigns: %{current_scope: scope}}

      assert {:reply, response, ^frame} =
               StartTask.execute(
                 %{requirement_id: requirement.id, session_id: session.id},
                 frame
               )

      refute response.isError
      content = response_text(response)

      # Prompt should come from the task module
      assert is_binary(content)
      # Data JSON should be appended
      assert content =~ "Data: "
      data = extract_data(content)
      assert data["task_id"]
      assert data["requirement_name"] == "test_spec"
      assert data["task_type"] == "ContextSpec"

      # DB state: task is active with correct linkage
      updated_session = Sessions.get_session(scope, session.id)
      task = Enum.find(updated_session.tasks, &(&1.requirement_name == "test_spec"))
      assert task.status == :active
      assert task.requirement_id == requirement.id
      assert task.component_id == requirement.component_id
      assert task.session_type == CodeMySpec.AgentTasks.ContextSpec
      assert task.started_at
    end

    test "assigns agent_id to the created task" do
      {scope, session, requirement} = setup_requirement()
      frame = %Frame{assigns: %{current_scope: scope}}

      assert {:reply, response, ^frame} =
               StartTask.execute(
                 %{requirement_id: requirement.id, session_id: session.id, agent_id: "agent-42"},
                 frame
               )

      refute response.isError

      updated_session = Sessions.get_session(scope, session.id)
      task = Enum.find(updated_session.tasks, &(&1.requirement_name == "test_spec"))
      assert task.agent_id == "agent-42"
    end

    test "resolves session by external_conversation_id" do
      {scope, _session, requirement} = setup_requirement()
      frame = %Frame{assigns: %{current_scope: scope}}

      external_id = "ext-conv-#{System.unique_integer([:positive])}"
      {:ok, ext_session} = Sessions.find_or_create_session(scope, external_id)

      assert {:reply, response, ^frame} =
               StartTask.execute(
                 %{requirement_id: requirement.id, session_id: external_id},
                 frame
               )

      refute response.isError

      updated_session = Sessions.get_session(scope, ext_session.id)
      task = Enum.find(updated_session.tasks, &(&1.requirement_name == "test_spec"))
      assert task.status == :active
    end
  end

  describe "execute/2 — deduplication" do
    test "returns prompt for already-active task without creating a duplicate" do
      {scope, session, requirement} = setup_requirement()
      frame = %Frame{assigns: %{current_scope: scope}}

      # First call creates the task
      {:reply, _, _} =
        StartTask.execute(%{requirement_id: requirement.id, session_id: session.id}, frame)

      # Reload session for second call
      updated_session = Sessions.get_session(scope, session.id)

      # Second call should return prompt, not create another task
      assert {:reply, response, ^frame} =
               StartTask.execute(
                 %{requirement_id: requirement.id, session_id: updated_session.id},
                 frame
               )

      refute response.isError
      assert response_text(response) =~ "Data: "

      final_session = Sessions.get_session(scope, session.id)
      matching = Enum.filter(final_session.tasks, &(&1.requirement_name == "test_spec"))
      assert length(matching) == 1
    end

    test "resumes a prepared task by activating it" do
      {scope, session, requirement} = setup_requirement()
      frame = %Frame{assigns: %{current_scope: scope}}

      # Manually prepare a task (simulates leftover from old flow)
      task_attrs = %{
        session_type: requirement.satisfied_by,
        requirement_id: requirement.id,
        requirement_name: requirement.name,
        project_id: scope.active_project_id,
        component_id: requirement.component_id
      }

      {:ok, session_with_prepared} = Sessions.prepare_task(scope, session, task_attrs)
      prepared_task = Enum.find(session_with_prepared.tasks, &(&1.status == :prepared))

      assert {:reply, response, ^frame} =
               StartTask.execute(
                 %{requirement_id: requirement.id, session_id: session_with_prepared.id},
                 frame
               )

      refute response.isError

      # Task should now be active
      final_session = Sessions.get_session(scope, session.id)
      task = Enum.find(final_session.tasks, &(&1.id == prepared_task.id))
      assert task.status == :active
    end
  end

  describe "execute/2 — error paths" do
    test "returns error for non-existent requirement" do
      scope = full_scope_fixture()
      session = session_fixture(scope)
      frame = %Frame{assigns: %{current_scope: scope}}

      assert {:reply, response, ^frame} =
               StartTask.execute(
                 %{requirement_id: Ecto.UUID.generate(), session_id: session.id},
                 frame
               )

      assert response.isError
      assert response_text(response) =~ "Requirement not found"
    end

    test "returns error for non-existent session" do
      scope = full_scope_fixture()
      component = component_fixture(scope)
      frame = %Frame{assigns: %{current_scope: scope}}

      requirement =
        requirement_fixture(scope, component, %{
          name: "test_spec",
          satisfied: false,
          satisfied_by: CodeMySpec.AgentTasks.ContextSpec
        })

      assert {:reply, response, ^frame} =
               StartTask.execute(
                 %{requirement_id: requirement.id, session_id: Ecto.UUID.generate()},
                 frame
               )

      assert response.isError
      assert response_text(response) =~ "Session not found"
    end

    test "returns error when session_id is missing" do
      scope = full_scope_fixture()
      component = component_fixture(scope)
      frame = %Frame{assigns: %{current_scope: scope}}

      requirement =
        requirement_fixture(scope, component, %{
          name: "test_spec",
          satisfied: false,
          satisfied_by: CodeMySpec.AgentTasks.ContextSpec
        })

      assert {:reply, response, ^frame} =
               StartTask.execute(%{requirement_id: requirement.id}, frame)

      assert response.isError
      assert response_text(response) =~ "No session_id"
    end

    test "returns error without valid scope" do
      frame = %Frame{assigns: %{}}

      assert {:reply, response, ^frame} =
               StartTask.execute(%{requirement_id: "1", session_id: "x"}, frame)

      assert response.isError
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp setup_requirement do
    scope = full_scope_fixture()
    component = component_fixture(scope)
    session = session_fixture(scope)

    requirement =
      requirement_fixture(scope, component, %{
        name: "test_spec",
        satisfied: false,
        satisfied_by: CodeMySpec.AgentTasks.ContextSpec
      })

    {scope, session, requirement}
  end

  defp response_text(response) do
    protocol = Response.to_protocol(response)
    hd(protocol["content"])["text"]
  end

  defp extract_data(text) do
    [_, json] = String.split(text, "Data: ", parts: 2)
    Jason.decode!(json)
  end
end
