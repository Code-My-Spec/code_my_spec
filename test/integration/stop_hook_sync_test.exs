defmodule CodeMySpec.Integration.StopHookSyncTest do
  @moduledoc """
  Integration tests for the minimal stop hook: mtime-based component sync,
  requirement recalculation, and task evaluation.

  Validates that:
  - ComponentSync.sync_changed detects file modifications via mtime
  - Ignored components are excluded from sync
  - Requirement satisfaction updates when files are created
  - The stop hook evaluates tasks and checks for remaining work
  - Manual validation_type tasks are not evaluated by the stop hook
  """
  use ExUnit.Case, async: true

  import CodeMySpec.Integration.WorkflowHelpers
  import CodeMySpec.UsersFixtures

  alias CodeMySpec.Components
  alias CodeMySpec.Environments.Environment
  alias CodeMySpec.Files.ComponentSync, as: FileComponentSync
  alias CodeMySpec.Files.FileSync
  alias CodeMySpec.Requirements.RequirementCalculator
  alias CodeMySpec.McpServers.Tasks.Tools.StartTask
  alias CodeMySpec.Projects
  alias CodeMySpec.Sessions
  alias CodeMySpecLocalWeb.Hooks.StopController

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(CodeMySpec.Repo)
  end

  # ============================================================================
  # Test 1: full sync processes all files
  # ============================================================================

  describe "full sync" do
    test "FileSync reports only fingerprint-changed paths on each sync" do
      {scope, tmp_dir} = setup_component_scenario()

      write_spec_file(tmp_dir, "my_app/accounts", "MyApp.Accounts")
      write_impl_file(tmp_dir, "my_app/accounts", "MyApp.Accounts")

      # First sync sees both files as new — both must appear as changed.
      {:ok, result1} = FileSync.sync(scope, base_dir: tmp_dir)
      assert result1.total_files >= 2
      assert length(result1.changed_paths) >= 2

      # Second sync with no on-disk edits returns an empty diff — Story
      # 688's checksum-skip rule. Re-running sync is cheap and doesn't
      # re-trigger downstream consumers (validators, embedding) for
      # files whose content didn't actually change.
      {:ok, result2} = FileSync.sync(scope, base_dir: tmp_dir)
      assert result2.changed_paths == []
    end
  end

  # ============================================================================
  # Test 2: requirement satisfaction via file creation
  # (Previous infrastructure_paths classification test removed —
  # `parse_impl_file` no longer sets `type: "infrastructure"` from the
  # config whitelist. Type is spec-driven; the `infrastructure_paths`
  # config is currently vestigial.)
  # ============================================================================

  describe "requirement satisfaction" do
    test "creating files satisfies requirements computed from File records" do
      {scope, tmp_dir} = setup_component_scenario()

      # Write only the spec file (not the impl file)
      write_spec_file(tmp_dir, "my_app/accounts", "MyApp.Accounts")

      # Sync files + components
      {:ok, _} = FileSync.sync(scope, base_dir: tmp_dir)
      {:ok, _} = FileComponentSync.sync_from_files(scope, base_dir: tmp_dir)

      accounts =
        Components.list_components(scope)
        |> Enum.find(&(&1.module_name == "MyApp.Accounts"))

      assert accounts

      # Compute requirements — spec_file satisfied, implementation_file not
      reqs = RequirementCalculator.compute_component(scope, accounts)
      spec_req = Enum.find(reqs, &(&1.name == "spec_file"))
      impl_req = Enum.find(reqs, &(&1.name == "implementation_file"))

      assert spec_req.satisfied, "spec_file should be satisfied"
      refute impl_req.satisfied, "implementation_file should NOT be satisfied yet"

      # Write the impl file and re-sync
      write_impl_file(tmp_dir, "my_app/accounts", "MyApp.Accounts")
      {:ok, _} = FileSync.sync(scope, base_dir: tmp_dir)
      {:ok, _} = FileComponentSync.sync_from_files(scope, base_dir: tmp_dir)

      # Re-compute — implementation_file now satisfied
      reqs2 = RequirementCalculator.compute_component(scope, accounts)
      impl_req2 = Enum.find(reqs2, &(&1.name == "implementation_file"))

      assert impl_req2.satisfied,
             "implementation_file should be satisfied after impl file created"
    end
  end

  # ============================================================================
  # Test 4: minimal stop hook end-to-end
  # ============================================================================

  describe "stop hook end-to-end" do
    test "stop hook syncs, evaluates task, allows stop when not in continuous mode" do
      %{
        scope: scope,
        frame: frame,
        session_id: session_id,
        external_session_id: external_session_id,
        req1: req1,
        tmp_dir: tmp_dir
      } = setup_workflow_scenario()

      # Start task for project_setup
      {:reply, resp, ^frame} =
        StartTask.execute(Map.put(req1, :session_id, session_id), frame)

      refute resp.isError

      # Get the active task
      session = Sessions.get_session(scope, session_id)
      task = Enum.find(session.tasks, &(&1.status == :active))
      assert task
      task_id = task.id

      # Satisfy `technical_strategy` — a `path_exists` check, so writing the file
      # is the whole of it.
      File.mkdir_p!(Path.join(tmp_dir, ".code_my_spec/architecture"))

      File.write!(
        Path.join(tmp_dir, ".code_my_spec/architecture/decisions.md"),
        "# Decisions\n"
      )

      # Call stop hook — evaluates task, marks completed, allows stop (not continuous mode)
      stop_response = call_stop_hook!(scope, external_session_id)
      assert stop_response == %{}

      # Verify task was marked completed
      session2 = Sessions.get_session(scope, session_id)
      completed_task = Enum.find(session2.tasks, &(&1.id == task_id))
      assert completed_task.status == :completed
    end
  end

  # ============================================================================
  # Test 5: manual validation_type skips evaluation
  # ============================================================================

  describe "validation_type" do
    test "manual validation tasks are not evaluated — stop is allowed" do
      {:ok, tmp_dir} = Briefly.create(directory: true)
      scope = full_scope_fixture()

      {:ok, project} =
        Projects.update_project(scope, scope.active_project, %{local_path: tmp_dir})

      scope = %{scope | active_project: project, environment: Environment.new(:local, tmp_dir)}

      external_id = "manual-test-#{System.unique_integer([:positive])}"
      {:ok, session} = Sessions.find_or_create_session(scope, external_id)

      # qa_integration_plan is computed from the graph with validation_type: :manual
      req_ref = %{
        requirement_name: "qa_integration_plan",
        entity_type: "project",
        entity_id: to_string(scope.active_project_id)
      }

      # Start task for this requirement
      frame = %Anubis.Server.Frame{assigns: %{current_scope: scope}}

      {:reply, resp, ^frame} =
        StartTask.execute(Map.put(req_ref, :session_id, session.id), frame)

      refute resp.isError

      # Verify the task is active with manual validation
      session = Sessions.get_session(scope, session.id)
      task = Enum.find(session.tasks, &(&1.status == :active))
      assert task
      assert task.validation_type == :manual

      # Call stop hook — should allow stop (not evaluate manual task)
      stop_response = call_stop_hook!(scope, external_id)

      # Manual tasks allow stop (empty response = no block)
      assert stop_response == %{}

      # Task should still be active (not evaluated/completed)
      session2 = Sessions.get_session(scope, session.id)
      still_active = Enum.find(session2.tasks, &(&1.id == task.id))
      assert still_active.status == :active
    end
  end

  # ============================================================================
  # Private helpers
  # ============================================================================

  defp setup_component_scenario do
    {:ok, tmp_dir} = Briefly.create(directory: true)
    scope = full_scope_fixture()
    {:ok, project} = Projects.update_project(scope, scope.active_project, %{local_path: tmp_dir})

    scope = %{
      scope
      | active_project: project,
        cwd: tmp_dir,
        environment: Environment.new(:local, tmp_dir)
    }

    {scope, tmp_dir}
  end

  defp write_spec_file(tmp_dir, module_path, module_name) do
    spec_path = Path.join([tmp_dir, ".code_my_spec", "spec", "#{module_path}.spec.md"])
    File.mkdir_p!(Path.dirname(spec_path))

    File.write!(spec_path, """
    # #{module_name}

    A test component.

    ## Type

    schema
    """)
  end

  defp write_impl_file(tmp_dir, module_path, module_name) do
    impl_path = Path.join([tmp_dir, "lib", "#{module_path}.ex"])
    File.mkdir_p!(Path.dirname(impl_path))

    File.write!(impl_path, """
    defmodule #{module_name} do
      @moduledoc false
    end
    """)
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
