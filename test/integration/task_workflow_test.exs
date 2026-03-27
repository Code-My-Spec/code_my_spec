defmodule CodeMySpec.Integration.TaskWorkflowTest do
  @moduledoc """
  Integration test for the core MCP tool workflow:
  get_next_requirement → start_task → evaluate_task → get_next_requirement

  Exercises the full chain using real DB state, no filesystem.
  """
  use ExUnit.Case, async: true

  import CodeMySpec.Integration.WorkflowHelpers

  alias CodeMySpec.McpServers.Requirements.Tools.GetNextRequirement
  alias CodeMySpec.McpServers.Tasks.Tools.{EvaluateTask, StartTask}
  alias CodeMySpec.Requirements.RequirementsRepository
  alias CodeMySpec.Sessions

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(CodeMySpec.Repo)
    setup_workflow_scenario()
  end

  test "full cycle: get_next → start → evaluate → satisfy → get_next returns next in graph",
       %{scope: scope, frame: frame, session_id: session_id, req1: req1} do
    # Step 1: get_next_requirement → returns spec_file (tests_passing is blocked)
    next_data = call_get_next!(frame)
    assert next_data["requirement_name"] == "spec_file"

    # Step 2: start_task → creates active task, returns prompt
    start_data = call_start_task!(frame, next_data["requirement_id"], session_id)
    task_id = start_data["task_id"]
    assert task_id

    # Step 3: evaluate_task → RefactorModule always passes → task completed
    call_evaluate_task!(frame, task_id, session_id)

    session = Sessions.get_session(scope, session_id)
    task = Enum.find(session.tasks, &(&1.id == task_id))
    assert task.status == :completed

    # Step 4: satisfy the requirement in DB (simulates sync after agent work)
    {:ok, _} =
      RequirementsRepository.update_requirement(scope, req1, %{satisfied: true, score: 1.0})

    # Step 5: get_next_requirement → returns tests_passing (now unblocked)
    next_data2 = call_get_next!(frame)
    assert next_data2["requirement_name"] == "tests_passing"
  end

  # ---------------------------------------------------------------------------
  # Tool call wrappers
  # ---------------------------------------------------------------------------

  defp call_get_next!(frame) do
    assert {:reply, resp, ^frame} = GetNextRequirement.execute(%{}, frame)
    refute resp.isError, "get_next_requirement failed: #{response_text(resp)}"
    extract_data(resp)
  end

  defp call_start_task!(frame, requirement_id, session_id) do
    assert {:reply, resp, ^frame} =
             StartTask.execute(%{requirement_id: requirement_id, session_id: session_id}, frame)

    refute resp.isError, "start_task failed: #{response_text(resp)}"
    extract_data(resp)
  end

  defp call_evaluate_task!(frame, task_id, session_id) do
    assert {:reply, resp, ^frame} =
             EvaluateTask.execute(%{task_id: task_id, session_id: session_id}, frame)

    refute resp.isError, "evaluate_task failed: #{response_text(resp)}"
    resp
  end
end
