defmodule CodeMySpec.Integration.ProjectSetupWorkflowTest do
  @moduledoc """
  Integration test for the core MCP tool workflow:
  get_next_requirement → start_task → stop hook evaluates → get_next_requirement

  Exercises the full chain using real DB state, tmp dir filesystem,
  and the actual stop hook HTTP endpoint.
  """
  use ExUnit.Case, async: true

  import CodeMySpec.Integration.WorkflowHelpers

  alias CodeMySpec.Files.FileSync
  alias CodeMySpec.McpServers.Requirements.Tools.GetNextRequirement
  alias CodeMySpec.McpServers.Tasks.Tools.StartTask
  alias CodeMySpec.Sessions
  alias CodeMySpecLocalWeb.Hooks.StopController
  alias Ecto.Adapters.SQL.Sandbox

  setup do
    :ok = Sandbox.checkout(CodeMySpec.Repo)
    setup_workflow_scenario()
  end

  test "full cycle: get_next → start → complete steps → stop hook evaluates → get_next",
       %{
         scope: scope,
         frame: frame,
         session_id: session_id,
         external_session_id: external_session_id,
         req1: req1,
         tmp_dir: tmp_dir
       } do
    # Step 1: get_next_requirement → returns project_setup (technical_strategy is blocked)
    next_text = call_get_next_text!(frame)
    assert next_text =~ "### ProjectSetup"
    assert next_text =~ "requirement `project_setup`"

    # Step 2: start_task → all 12 steps unchecked (empty tmp dir)
    prompt = call_start_task_text!(frame, req1, session_id)
    assert prompt =~ "Project Setup (0/12)"
    assert prompt =~ "- [ ] **Claude md**"
    assert prompt =~ "Task ID:"

    # Get task_id from DB
    session = Sessions.get_session(scope, session_id)
    task = Enum.find(session.tasks, &(&1.status == :active))
    assert task
    task_id = task.id

    # Step 3: simulate agent completing one step — write CLAUDE.md with managed section.
    # Since 403b3cc, setup checks read from File records (sync-time), not the
    # filesystem directly — sync changed files after writing.
    claude_md_path = Path.join(tmp_dir, "CLAUDE.md")
    File.write!(claude_md_path, "# Project\n<!-- code_my_spec:start -->\nmanaged\n<!-- code_my_spec:end -->")
    {:ok, _} = FileSync.sync_changed(scope, base_dir: tmp_dir)

    # Step 4: start_task again → Claude md now shows [x], count is 1/12
    prompt2 = call_start_task_text!(frame, req1, session_id)
    assert prompt2 =~ "Project Setup (1/12)"
    assert prompt2 =~ "- [x] **Claude md**"

    # Step 5: seed all remaining steps in the tmp dir
    seed_all_setup_steps(tmp_dir)
    {:ok, _} = FileSync.sync_changed(scope, base_dir: tmp_dir)

    # Step 6: start_task again → all 12 steps now satisfied
    prompt3 = call_start_task_text!(frame, req1, session_id)
    assert prompt3 =~ "Project Setup (12/12)"
    refute prompt3 =~ "- [ ] "

    # Step 7: stop hook → evaluates task → passes → allows stop (not in continuous mode)
    stop_response = call_stop_hook!(scope, external_session_id)
    assert stop_response == %{}

    # Verify task is completed in DB
    session2 = Sessions.get_session(scope, session_id)
    completed_task = Enum.find(session2.tasks, &(&1.id == task_id))
    assert completed_task.status == :completed

    # Step 8: get_next_requirement → project_setup satisfied from filesystem.
    # The next gate is `personas_complete`; stories_exist now waits on it,
    # and technical_strategy waits on stories_exist.
    next_text2 = call_get_next_text!(frame)
    assert next_text2 =~ "### PersonaResearch"
    assert next_text2 =~ "requirement_name=`personas_complete`"
  end

  # ---------------------------------------------------------------------------
  # Tool call wrappers
  # ---------------------------------------------------------------------------

  defp call_get_next_text!(frame) do
    assert {:reply, resp, ^frame} = GetNextRequirement.execute(%{}, frame)
    refute resp.isError, "get_next_requirement failed: #{response_text(resp)}"
    response_text(resp)
  end

  defp call_start_task_text!(frame, req, session_id) do
    params = Map.put(req, :session_id, session_id)

    assert {:reply, resp, ^frame} = StartTask.execute(params, frame)

    refute resp.isError, "start_task failed: #{response_text(resp)}"
    response_text(resp)
  end

  defp call_stop_hook!(scope, session_id) do
    conn =
      Phoenix.ConnTest.build_conn(:post, "/api/hooks/stop", %{"session_id" => session_id})
      |> Plug.Conn.assign(:current_scope, scope)
      |> Plug.Conn.put_private(:phoenix_format, "json")
      |> Map.put(:body_params, %{"session_id" => session_id})

    conn = StopController.handle(conn, conn.body_params)
    Jason.decode!(conn.resp_body)
  end
end
