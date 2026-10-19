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

  alias CodeMySpec.ToolLibrary

  import CodeMySpec.Integration.WorkflowHelpers
  import CodeMySpec.UsersFixtures

  alias CodeMySpec.Components
  alias CodeMySpec.Environments.Environment
  alias CodeMySpec.Files.ComponentSync, as: FileComponentSync
  alias CodeMySpec.Files.FileSync
  alias CodeMySpec.Hooks.Stop
  alias CodeMySpec.Projects
  alias CodeMySpec.Requirements.RequirementCalculator
  alias CodeMySpec.Agents
  alias CodeMySpec.TerminalAgentFixtures
  alias Ecto.Adapters.SQL.Sandbox

  setup do
    :ok = Sandbox.checkout(CodeMySpec.Repo)
  end

  # ============================================================================
  # Test 1: full sync processes all files
  # ============================================================================

  describe "full sync" do
    test "FileSync reports only fingerprint-changed paths on each sync" do
      {scope, tmp_dir} = setup_component_scenario()

      write_impl_file(tmp_dir, "my_app/accounts", "MyApp.Accounts")
      File.mkdir_p!(Path.join(tmp_dir, "test/my_app"))
      File.write!(Path.join(tmp_dir, "test/my_app/accounts_test.exs"), "# accounts test\n")

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

      # The component is a record, authored before any code exists.
      {:ok, accounts} =
        Components.create_component(scope, %{
          name: "Accounts",
          module_name: "MyApp.Accounts",
          type: "context",
          provenance: :authored
        })

      # Only implementation is required.
      reqs = RequirementCalculator.compute_component(scope, accounts)
      spec_req = Enum.find(reqs, &(&1.name == "spec_file"))
      impl_req = Enum.find(reqs, &(&1.name == "implementation_file"))

      assert is_nil(spec_req), "specification is not a component work requirement"
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

      # The requirement has to be in the graph before a task can start on it.
      CodeMySpec.Requirements.recompute(scope)

      # Start task for project_setup
      resp =
        ToolLibrary.run(
          "start_task",
          Map.put(req1, :session_id, session_id),
          Map.put(frame.assigns, :scope, frame.assigns[:current_scope])
        )

      assert match?({:ok, _}, resp)

      {:ok, session} = Agents.fetch_owner(scope, nil, session_id)
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
      {:ok, session2} = Agents.fetch_owner(scope, nil, session_id)
      completed_task = Enum.find(session2.tasks, &(&1.id == task_id))
      assert completed_task.status == :completed
    end
  end

  # ============================================================================
  # Test 5: manual validation_type skips evaluation
  # ============================================================================

  describe "validation_type" do
    test "manual validation tasks are not evaluated — stop is allowed" do
      tmp_dir = CodeMySpec.TempFile.owned_dir("test")
      scope = full_scope_fixture()

      {:ok, project} =
        Projects.update_project(scope, scope.active_project, %{local_path: tmp_dir})

      scope =
        CodeMySpec.UsersFixtures.put_fixture_environment(
          %{scope | active_project: project},
          Environment.new(:local, tmp_dir)
        )

      external_id = "manual-test-#{System.unique_integer([:positive])}"

      session =
        TerminalAgentFixtures.terminal_agent_fixture(scope, %{engine_session_id: external_id})

      # qa_integration_plan is computed from the graph with validation_type: :manual
      req_ref = %{
        requirement_name: "qa_integration_plan",
        entity_type: "project",
        entity_id: to_string(scope.active_project_id)
      }

      # The requirement has to be in the graph before a task can start on it.
      CodeMySpec.Requirements.recompute(scope)

      # Start task for this requirement
      frame = %Anubis.Server.Frame{assigns: %{current_scope: scope}}

      resp =
        ToolLibrary.run(
          "start_task",
          Map.put(req_ref, :session_id, external_id),
          Map.put(frame.assigns, :scope, frame.assigns[:current_scope])
        )

      assert match?({:ok, _}, resp)

      {:ok, session} = Agents.fetch_owner(scope, nil, external_id)
      task = Enum.find(session.tasks, &(&1.status == :active))
      assert task
      assert task.validation_type == :manual

      # Call stop hook — should allow stop (not evaluate manual task)
      stop_response = call_stop_hook!(scope, external_id)

      # Manual tasks allow stop (empty response = no block)
      assert stop_response == %{}

      # Task should still be active (not evaluated/completed)
      {:ok, session2} = Agents.fetch_owner(scope, nil, external_id)
      still_active = Enum.find(session2.tasks, &(&1.id == task.id))
      assert still_active.status == :active
    end
  end

  # ============================================================================
  # Private helpers
  # ============================================================================

  defp setup_component_scenario do
    tmp_dir = CodeMySpec.TempFile.owned_dir("test")
    scope = full_scope_fixture()
    {:ok, project} = Projects.update_project(scope, scope.active_project, %{local_path: tmp_dir})

    scope =
      put_fixture_environment(
        %{scope | active_project: project},
        Environment.new(:local, tmp_dir)
      )

    {scope, tmp_dir}
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
    body_params = %{"session_id" => session_id}

    scope
    |> Stop.decide(body_params)
    |> Jason.encode!()
    |> Jason.decode!()
  end
end
