defmodule CodeMySpec.Integration.TaskWorkflowTest do
  @moduledoc """
  Integration test for the core MCP tool workflow:
  get_next_requirement → start_task → satisfy → get_next_requirement

  Exercises the full chain using real DB state, no filesystem.
  """
  use ExUnit.Case, async: true

  import CodeMySpec.Integration.WorkflowHelpers

  alias CodeMySpec.McpServers.Requirements.Tools.GetNextRequirement
  alias CodeMySpec.McpServers.Tasks.Tools.StartTask
  alias CodeMySpec.Requirements.RequirementsRepository
  alias CodeMySpec.Sessions

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(CodeMySpec.Repo)
    setup_workflow_scenario()
  end

  test "full cycle: get_next → start → complete a step → prompt reflects it → satisfy → get_next",
       %{scope: scope, frame: frame, session_id: session_id, req1: req1, tmp_dir: tmp_dir} do
    # Step 1: get_next_requirement → returns project_setup (technical_strategy is blocked)
    next_data = call_get_next!(frame)
    assert next_data["requirement_name"] == "project_setup"

    # Step 2: start_task → all 13 steps unchecked (empty tmp dir)
    start_data = call_start_task!(frame, next_data["requirement_id"], session_id)
    prompt = call_start_task_text!(frame, next_data["requirement_id"], session_id)
    assert prompt =~ "Project Setup (0/12)"
    assert prompt =~ "- [ ] **Claude md**"

    task_id = start_data["task_id"]
    assert task_id

    # Verify task is active in DB
    session = Sessions.get_session(scope, session_id)
    task = Enum.find(session.tasks, &(&1.id == task_id))
    assert task.status == :active

    # Step 3: simulate agent completing one step — write CLAUDE.md with managed section
    claude_md_path = Path.join(tmp_dir, "CLAUDE.md")
    File.write!(claude_md_path, "# Project\n<!-- code_my_spec:start -->\nmanaged\n<!-- code_my_spec:end -->")

    # Step 4: start_task again → Claude md now shows [x], count is 1/12
    prompt2 = call_start_task_text!(frame, next_data["requirement_id"], session_id)
    assert prompt2 =~ "Project Setup (1/12)"
    assert prompt2 =~ "- [x] **Claude md**"

    # Step 5: seed all remaining steps in the tmp dir
    seed_all_setup_steps(tmp_dir)

    # Step 6: start_task again → all 12 steps now satisfied
    prompt3 = call_start_task_text!(frame, next_data["requirement_id"], session_id)
    assert prompt3 =~ "Project Setup (12/12)"
    refute prompt3 =~ "- [ ] "

    # Step 7: satisfy the requirement in DB (simulates full sync marking project_setup done)
    {:ok, _} =
      RequirementsRepository.update_requirement(scope, req1, %{satisfied: true, score: 1.0})

    # Step 8: get_next_requirement → returns technical_strategy (now unblocked)
    next_data2 = call_get_next!(frame)
    assert next_data2["requirement_name"] == "technical_strategy"
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

  defp call_start_task_text!(frame, requirement_id, session_id) do
    assert {:reply, resp, ^frame} =
             StartTask.execute(%{requirement_id: requirement_id, session_id: session_id}, frame)

    refute resp.isError, "start_task failed: #{response_text(resp)}"
    response_text(resp)
  end
end
