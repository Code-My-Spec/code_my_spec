defmodule CodeMySpec.ProjectCoordinator.OrchestrationTest do
  use CodeMySpec.DataCase, async: true

  import CodeMySpec.AccountsFixtures
  import CodeMySpec.ComponentsFixtures
  import CodeMySpec.ProjectsFixtures
  import CodeMySpec.UsersFixtures

  alias CodeMySpec.Components.ComponentRepository
  alias CodeMySpec.ProjectCoordinator
  alias CodeMySpec.Requirements

  setup do
    user = user_fixture()
    account = account_with_owner_fixture(user)
    scope = user_scope_fixture(user, account)
    project = project_fixture(scope)
    scope = user_scope_fixture(user, account, project)

    %{scope: scope, project: project}
  end

  describe "collect_components/2" do
    test "non-container type returns only the component itself", %{scope: scope} do
      component = component_fixture(scope, %{type: "genserver"})
      result = ProjectCoordinator.collect_components(scope, component)

      assert length(result) == 1
      assert hd(result).id == component.id
    end

    test "context type returns component + descendants", %{scope: scope} do
      context = component_fixture(scope, %{type: "context", module_name: "TestApp.Accounts"})
      schema = component_fixture(scope, %{type: "schema", module_name: "TestApp.Accounts.User", parent_component_id: context.id})

      result = ProjectCoordinator.collect_components(scope, context)

      assert length(result) == 2
      ids = Enum.map(result, & &1.id)
      assert context.id in ids
      assert schema.id in ids
    end

    test "live_context type returns component + descendants", %{scope: scope} do
      live_ctx = component_fixture(scope, %{type: "live_context", module_name: "TestApp.DashboardLive"})
      _lv = component_fixture(scope, %{type: "liveview", module_name: "TestApp.DashboardLive.Index", parent_component_id: live_ctx.id})

      result = ProjectCoordinator.collect_components(scope, live_ctx)
      assert length(result) == 2
    end
  end

  describe "find_actionable/2" do
    test "finds actionable work for fresh components", %{scope: scope} do
      component = component_fixture(scope, %{type: "genserver"}) |> reload(scope)
      components = [component]

      result = ProjectCoordinator.find_actionable(scope, components)

      assert length(result) == 1
      item = hd(result)
      assert item.task_module == CodeMySpec.AgentTasks.ComponentSpec
      assert item.component.id == component.id
      defn_names = Enum.map(item.definitions, & &1.name)
      assert "spec_file" in defn_names
    end

    test "finds nothing for fully satisfied component", %{scope: scope} do
      component = component_fixture(scope, %{type: "schema"})

      for {name, artifact_type} <- [
            {"spec_file", :specification},
            {"spec_valid", :specification},
            {"implementation_file", :code}
          ] do
        {:ok, _} =
          Requirements.create_requirement(scope, component, %{
            name: name,
            artifact_type: artifact_type,
            description: "test",
            checker_module: CodeMySpec.Requirements.FileExistenceChecker,
            satisfied: true,
            score: 1.0,
            checked_at: DateTime.utc_now()
          })
      end

      component = reload(component, scope)
      result = ProjectCoordinator.find_actionable(scope, [component])
      assert result == []
    end

    test "finds actionable across multiple components", %{scope: scope} do
      comp1 = component_fixture(scope, %{type: "schema", module_name: "TestApp.User"}) |> reload(scope)
      comp2 = component_fixture(scope, %{type: "genserver", module_name: "TestApp.Server"}) |> reload(scope)

      result = ProjectCoordinator.find_actionable(scope, [comp1, comp2])

      # Both should have spec_file actionable
      assert length(result) == 2
      component_ids = Enum.map(result, & &1.component.id)
      assert comp1.id in component_ids
      assert comp2.id in component_ids
    end
  end

  describe "find_remaining/2" do
    test "returns empty for fully satisfied component", %{scope: scope} do
      component = component_fixture(scope, %{type: "schema"})

      for {name, artifact_type} <- [
            {"spec_file", :specification},
            {"spec_valid", :specification},
            {"implementation_file", :code}
          ] do
        {:ok, _} =
          Requirements.create_requirement(scope, component, %{
            name: name,
            artifact_type: artifact_type,
            description: "test",
            checker_module: CodeMySpec.Requirements.FileExistenceChecker,
            satisfied: true,
            score: 1.0,
            checked_at: DateTime.utc_now()
          })
      end

      component = reload(component, scope)
      result = ProjectCoordinator.find_remaining(scope, [component])
      assert result == []
    end

    test "returns unsatisfied requirements", %{scope: scope} do
      component = component_fixture(scope, %{type: "schema"})

      {:ok, _} =
        Requirements.create_requirement(scope, component, %{
          name: "spec_file",
          artifact_type: :specification,
          description: "test",
          checker_module: CodeMySpec.Requirements.FileExistenceChecker,
          satisfied: true,
          score: 1.0,
          checked_at: DateTime.utc_now()
        })

      {:ok, _} =
        Requirements.create_requirement(scope, component, %{
          name: "spec_valid",
          artifact_type: :specification,
          description: "test",
          checker_module: CodeMySpec.Requirements.DocumentValidityChecker,
          satisfied: false,
          score: 0.0,
          checked_at: DateTime.utc_now()
        })

      component = reload(component, scope)
      result = ProjectCoordinator.find_remaining(scope, [component])
      names = Enum.map(result, & &1.name)
      assert "spec_valid" in names
    end
  end

  describe "component_status_dir/1" do
    test "converts module name to status directory path" do
      component = %{module_name: "MetricFlow.Accounts"}
      assert ProjectCoordinator.component_status_dir(component) == ".code_my_spec/status/metric_flow/accounts"
    end

    test "handles deeply nested modules" do
      component = %{module_name: "MyApp.Web.Live.Dashboard"}
      assert ProjectCoordinator.component_status_dir(component) == ".code_my_spec/status/my_app/web/live/dashboard"
    end
  end

  describe "safe_filename/1" do
    test "converts module name to safe filename" do
      assert ProjectCoordinator.safe_filename("MetricFlow.Accounts") == "metricflow_accounts"
    end
  end

  describe "build_orchestration_prompt/3" do
    test "returns complete message when no prompt files" do
      component = %{name: "Accounts"}
      result = ProjectCoordinator.build_orchestration_prompt(component, [], "status/dir")
      assert result =~ "All Requirements Satisfied"
    end

    test "returns task list when prompt files exist" do
      component = %{name: "Accounts", id: "123", type: "context"}

      prompt_files = [
        %{
          component: component,
          task_module: CodeMySpec.AgentTasks.ComponentSpec,
          file_path: "status/accounts_component_spec.md",
          suffix: "component_spec"
        }
      ]

      result = ProjectCoordinator.build_orchestration_prompt(component, prompt_files, "status/dir")
      assert result =~ "Development: Accounts"
      assert result =~ "status/accounts_component_spec.md"
      assert result =~ "spec-writer"
    end
  end

  # Helpers

  defp reload(component, scope) do
    ComponentRepository.get_component(scope, component.id)
  end
end
