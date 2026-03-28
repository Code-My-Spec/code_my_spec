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
  alias CodeMySpec.McpServers.Tasks.Tools.StartTask
  alias CodeMySpec.Projects
  alias CodeMySpec.ProjectSync.Sync, as: ProjectSync
  alias CodeMySpec.Sessions
  alias CodeMySpecLocalWeb.Hooks.StopController

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(CodeMySpec.Repo)
  end

  # ============================================================================
  # Test 1: mtime tracking detects modified components
  # ============================================================================

  describe "mtime tracking" do
    test "sync_changed detects modified files and updates files_changed_at" do
      {scope, tmp_dir} = setup_component_scenario()

      # Write spec + impl for MyApp.Accounts
      write_spec_file(tmp_dir, "my_app/accounts", "MyApp.Accounts")
      write_impl_file(tmp_dir, "my_app/accounts", "MyApp.Accounts")

      # First sync — creates component, records mtimes
      {:ok, result1} = ProjectSync.incremental_sync(scope, base_dir: tmp_dir)
      assert length(result1.all_components) >= 1

      accounts = find_component(result1.all_components, "MyApp.Accounts")
      assert accounts
      original_changed_at = accounts.files_changed_at

      # Wait for filesystem mtime granularity (1 second on HFS+/APFS)
      Process.sleep(1100)

      # Modify the spec file
      write_spec_file(tmp_dir, "my_app/accounts", "MyApp.Accounts")

      # Second sync — detects the change
      {:ok, result2} = ProjectSync.incremental_sync(scope, base_dir: tmp_dir)

      updated_accounts =
        Components.list_components(scope)
        |> Enum.find(&(&1.module_name == "MyApp.Accounts"))

      assert updated_accounts
      assert DateTime.compare(updated_accounts.files_changed_at, original_changed_at) == :gt
      assert updated_accounts.id in result2.changed_ids
    end
  end

  # ============================================================================
  # Test 2: ignored components excluded from tracking
  # ============================================================================

  describe "ignored components" do
    test "components in ignored_components config are excluded from sync" do
      {scope, tmp_dir} = setup_component_scenario()

      # Write config with ignored components
      config_dir = Path.join(tmp_dir, ".code_my_spec")
      File.mkdir_p!(config_dir)

      File.write!(Path.join(config_dir, "config.yml"), """
      ignored_components:
        - "MyApp.Ignored"
      """)

      # Write files for both tracked and ignored components
      write_spec_file(tmp_dir, "my_app/tracked", "MyApp.Tracked")
      write_impl_file(tmp_dir, "my_app/tracked", "MyApp.Tracked")
      write_spec_file(tmp_dir, "my_app/ignored", "MyApp.Ignored")
      write_impl_file(tmp_dir, "my_app/ignored", "MyApp.Ignored")

      # Sync
      {:ok, result} = ProjectSync.incremental_sync(scope, base_dir: tmp_dir)

      IO.inspect(result)

      module_names = Enum.map(result.all_components, & &1.module_name)
      assert "MyApp.Tracked" in module_names
      refute "MyApp.Ignored" in module_names
    end
  end

  # ============================================================================
  # Test 3: requirement satisfaction via file creation
  # ============================================================================

  describe "requirement satisfaction" do
    test "creating files satisfies FileExistence requirements after sync" do
      {scope, tmp_dir} = setup_component_scenario()

      # Write only the spec file (not the impl file)
      write_spec_file(tmp_dir, "my_app/accounts", "MyApp.Accounts")

      # First sync — spec_file should be satisfied, implementation_file should not
      {:ok, _} = ProjectSync.incremental_sync(scope, base_dir: tmp_dir)

      accounts_id =
        Components.list_components(scope)
        |> Enum.find(&(&1.module_name == "MyApp.Accounts"))
        |> Map.fetch!(:id)

      # get_component preloads :requirements
      accounts = Components.get_component(scope, accounts_id)
      assert accounts

      spec_req = Enum.find(accounts.requirements, &(&1.name == "spec_file"))
      impl_req = Enum.find(accounts.requirements, &(&1.name == "implementation_file"))

      assert spec_req, "spec_file requirement should exist"
      assert spec_req.satisfied, "spec_file should be satisfied (file exists)"

      if impl_req do
        refute impl_req.satisfied, "implementation_file should NOT be satisfied yet"
      end

      # Now write the impl file
      write_impl_file(tmp_dir, "my_app/accounts", "MyApp.Accounts")

      # Re-sync — implementation_file should now be satisfied
      {:ok, _} = ProjectSync.incremental_sync(scope, base_dir: tmp_dir)

      accounts2 = Components.get_component(scope, accounts_id)
      impl_req2 = Enum.find(accounts2.requirements, &(&1.name == "implementation_file"))

      assert impl_req2, "implementation_file requirement should exist after impl file created"

      assert impl_req2.satisfied,
             "implementation_file should be satisfied after impl file created"
    end
  end

  # ============================================================================
  # Test 4: minimal stop hook end-to-end
  # ============================================================================

  describe "stop hook end-to-end" do
    test "stop hook syncs, evaluates task, and blocks when more work exists" do
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
        StartTask.execute(%{requirement_id: to_string(req1.id), session_id: session_id}, frame)

      refute resp.isError

      # Get the active task
      session = Sessions.get_session(scope, session_id)
      task = Enum.find(session.tasks, &(&1.status == :active))
      assert task
      task_id = task.id

      # Seed all setup steps so ProjectSetup.evaluate passes
      seed_all_setup_steps(tmp_dir)

      # Call stop hook — should evaluate task, mark completed, block for more work
      stop_response = call_stop_hook!(scope, external_session_id)
      assert stop_response["decision"] == "block"
      assert stop_response["reason"] =~ "get_next_requirement"

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

      # Create a requirement with validation_type: :manual
      req =
        project_requirement_fixture(scope, %{
          name: "qa_integration_plan",
          artifact_type: :specification,
          satisfied: false,
          satisfied_by: CodeMySpec.AgentTasks.QaIntegrationPlan,
          validation_type: :manual
        })

      # Start task for this requirement
      frame = %Anubis.Server.Frame{assigns: %{current_scope: scope}}

      {:reply, resp, ^frame} =
        StartTask.execute(%{requirement_id: to_string(req.id), session_id: session.id}, frame)

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

  defp find_component(components, module_name) do
    Enum.find(components, &(&1.module_name == module_name))
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
