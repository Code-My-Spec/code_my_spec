defmodule CodeMySpec.ProjectCoordinator.OrchestrationTest do
  use CodeMySpecTest.DataCase, async: true

  alias CodeMySpec.ProjectCoordinator

  describe "component_status_dir/1" do
    test "converts module name to status directory path" do
      component = %{module_name: "MetricFlow.Accounts"}
      assert ProjectCoordinator.component_status_dir(component) == ".code_my_spec/tasks/metric_flow/accounts"
    end

    test "handles deeply nested modules" do
      component = %{module_name: "MyApp.Web.Live.Dashboard"}
      assert ProjectCoordinator.component_status_dir(component) == ".code_my_spec/tasks/my_app/web/live/dashboard"
    end
  end

  describe "safe_filename/1" do
    test "converts module name to safe filename" do
      assert ProjectCoordinator.safe_filename("MetricFlow.Accounts") == "accounts"
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
end
