defmodule CodeMySpec.Agents.Tools.EvaluateTaskTest do
  use ExUnit.Case, async: true

  alias CodeMySpec.ToolLibrary

  import CodeMySpec.ComponentsFixtures
  import CodeMySpec.IssuesFixtures
  import CodeMySpec.TerminalAgentFixtures
  import CodeMySpec.UsersFixtures

  alias Anubis.Server.Frame
  alias CodeMySpec.Repo
  alias CodeMySpec.TaskOwner
  alias Ecto.Adapters.SQL.Sandbox

  setup do
    :ok = Sandbox.checkout(Repo)
  end

  describe "execute/2 — terminal state" do
    test "returns already-terminal for completed task" do
      {scope, agent, task} = setup_active_task()
      frame = %Frame{assigns: %{current_scope: scope}}

      {:ok, _} = TaskOwner.complete_task(scope, agent, task.id, :completed)

      response =
        ToolLibrary.run(
          "evaluate_task",
          %{task_id: task.id, session_id: agent.engine_session_id},
          Map.put(frame.assigns, :scope, frame.assigns[:current_scope])
        )

      assert match?({:ok, _}, response)
      content = response_text(response)
      assert content =~ "already completed"
      assert content =~ "get_next_requirement"
    end
  end

  describe "execute/2 — owner resolution" do
    test "resolves the terminal agent by the session id the hook injects" do
      scope = full_scope_fixture()
      component = component_fixture(scope)
      frame = %Frame{assigns: %{current_scope: scope}}

      external_id = "ext-eval-#{System.unique_integer([:positive])}"

      agent =
        terminal_agent_fixture(scope, %{
          engine_session_id: external_id,
          tasks: [
            %{
              status: :completed,
              session_type: CodeMySpec.AgentTasks.ComponentCode,
              requirement_name: "implementation_file",
              project_id: scope.active_project_id,
              component_id: component.id
            }
          ]
        })

      task = hd(agent.tasks)

      response =
        ToolLibrary.run(
          "evaluate_task",
          %{task_id: task.id, session_id: external_id},
          Map.put(frame.assigns, :scope, frame.assigns[:current_scope])
        )

      assert match?({:ok, _}, response)
      assert response_text(response) =~ "already completed"
    end
  end

  describe "execute/2 — IssueQa dispatches to its own evaluate/2" do
    test "an issue-bound qa_complete task is skipped, not routed through the generic calculator" do
      scope = full_scope_fixture()
      issue = issue_fixture(scope)
      frame = %Frame{assigns: %{current_scope: scope}}

      external_id = "ext-issue-qa-#{System.unique_integer([:positive])}"

      agent =
        terminal_agent_fixture(scope, %{
          engine_session_id: external_id,
          tasks: [
            %{
              status: :active,
              session_type: CodeMySpec.AgentTasks.IssueQa,
              requirement_name: "qa_complete",
              project_id: scope.active_project_id,
              issue_id: issue.id
            }
          ]
        })

      task = hd(agent.tasks)

      response =
        ToolLibrary.run(
          "evaluate_task",
          %{task_id: task.id, session_id: external_id},
          Map.put(frame.assigns, :scope, frame.assigns[:current_scope])
        )

      assert match?({:ok, _}, response),
             "an issue-bound qa_complete task must dispatch to IssueQa.evaluate/2, not fall " <>
               "through to the generic Evaluator and fail looking up qa_complete as a " <>
               "project-level requirement"

      assert response_text(response) =~ "submit_issue_qa_result"
    end
  end

  describe "execute/2 — error paths" do
    test "returns error for a session that is no registered agent" do
      scope = full_scope_fixture()
      frame = %Frame{assigns: %{current_scope: scope}}

      response =
        ToolLibrary.run(
          "evaluate_task",
          %{task_id: Ecto.UUID.generate(), session_id: Ecto.UUID.generate()},
          Map.put(frame.assigns, :scope, frame.assigns[:current_scope])
        )

      assert match?({:error, _}, response)
      assert response_text(response) =~ "No agent found"
    end

    test "returns error for non-existent task" do
      scope = full_scope_fixture()
      agent = terminal_agent_fixture(scope)
      frame = %Frame{assigns: %{current_scope: scope}}

      response =
        ToolLibrary.run(
          "evaluate_task",
          %{task_id: Ecto.UUID.generate(), session_id: agent.engine_session_id},
          Map.put(frame.assigns, :scope, frame.assigns[:current_scope])
        )

      assert match?({:error, _}, response)
      assert response_text(response) =~ "Task not found"
    end

    test "returns error when session_id is missing" do
      scope = full_scope_fixture()
      frame = %Frame{assigns: %{current_scope: scope}}

      response =
        ToolLibrary.run(
          "evaluate_task",
          %{task_id: Ecto.UUID.generate()},
          Map.put(frame.assigns, :scope, frame.assigns[:current_scope])
        )

      assert match?({:error, _}, response)
      assert response_text(response) =~ "No agent found"
    end

    test "returns error without valid scope" do
      frame = %Frame{assigns: %{}}

      response =
        ToolLibrary.run(
          "evaluate_task",
          %{task_id: "whatever", session_id: "anything"},
          Map.put(frame.assigns, :scope, frame.assigns[:current_scope])
        )

      assert match?({:error, _}, response)
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp setup_active_task(task_module \\ CodeMySpec.AgentTasks.ComponentCode) do
    scope = full_scope_fixture()
    component = component_fixture(scope)

    agent =
      terminal_agent_fixture(scope, %{
        tasks: [
          %{
            status: :active,
            session_type: task_module,
            requirement_name: "implementation_file",
            project_id: scope.active_project_id,
            component_id: component.id,
            component_module_name: component.module_name
          }
        ]
      })

    {scope, agent, hd(agent.tasks)}
  end

  defp response_text({_status, text}), do: text
end
