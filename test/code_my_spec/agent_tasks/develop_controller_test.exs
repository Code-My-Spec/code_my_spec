defmodule CodeMySpec.AgentTasks.DevelopControllerTest do
  use CodeMySpecTest.DataCase, async: true

  alias CodeMySpec.AgentTasks.DevelopController
  alias CodeMySpec.Components
  alias CodeMySpec.Environments.Environment

  import CodeMySpec.UsersFixtures
  import CodeMySpec.ComponentsFixtures
  import CodeMySpec.RequirementsFixtures

  @moduletag :tmp_dir

  defp create_scope_with_env(tmp_dir) do
    scope = full_scope_fixture()
    %{scope | environment: Environment.new(:local, tmp_dir)}
  end

  defp create_task(scope, component) do
    %{component_id: component.id, project_id: scope.active_project.id, story_id: nil}
  end

  defp create_controller_component(scope) do
    component_fixture(scope, %{
      name: "UserController",
      type: "controller",
      module_name: "TestAppWeb.UserController"
    })
  end

  describe "command/3" do
    test "returns static development instructions with controller name", %{tmp_dir: tmp_dir} do
      scope = create_scope_with_env(tmp_dir)
      controller = create_controller_component(scope)
      task = create_task(scope, controller)

      assert {:ok, prompt} = DevelopController.command(scope, task)
      assert prompt =~ "Develop Controller: UserController"
      assert prompt =~ "Controller Spec"
      assert prompt =~ "Implementation"
      assert prompt =~ "JSON view"
    end

    test "generates JSON view stub spec on command", %{tmp_dir: tmp_dir} do
      scope = create_scope_with_env(tmp_dir)
      controller = create_controller_component(scope)
      task = create_task(scope, controller)

      json_spec_path = Path.join(tmp_dir, ".code_my_spec/spec/test_app_web/user_json.spec.md")
      refute File.exists?(json_spec_path)

      assert {:ok, _prompt} = DevelopController.command(scope, task)

      assert File.exists?(json_spec_path)
      content = File.read!(json_spec_path)
      assert content =~ "TestAppWeb.UserJSON"
      assert content =~ "json"
    end

    test "does not overwrite existing JSON view spec", %{tmp_dir: tmp_dir} do
      scope = create_scope_with_env(tmp_dir)
      controller = create_controller_component(scope)
      task = create_task(scope, controller)

      json_spec_path = Path.join(tmp_dir, ".code_my_spec/spec/test_app_web/user_json.spec.md")
      json_spec_path |> Path.dirname() |> File.mkdir_p!()
      File.write!(json_spec_path, "# Custom spec\n\nCustom content")

      assert {:ok, _prompt} = DevelopController.command(scope, task)
      assert File.read!(json_spec_path) =~ "Custom content"
    end
  end

  describe "evaluate/3" do
    test "returns {:ok, :valid} when all requirements satisfied", %{tmp_dir: tmp_dir} do
      scope = create_scope_with_env(tmp_dir)
      controller = create_controller_component(scope)

      for name <- ["spec_file", "spec_valid", "implementation_file", "test_file", "tests_passing"] do
        requirement_fixture(scope, controller, %{
          name: name,
          artifact_type: :specification,
          satisfied: true
        })
      end

      controller = Components.get_component(scope, controller.id)
      task = create_task(scope, controller)

      assert {:ok, :valid} = DevelopController.evaluate(scope, task)
    end

    test "returns {:ok, :invalid, feedback} when requirements unsatisfied", %{tmp_dir: tmp_dir} do
      scope = create_scope_with_env(tmp_dir)
      controller = create_controller_component(scope)

      requirement_fixture(scope, controller, %{
        name: "spec_file",
        artifact_type: :specification,
        satisfied: false
      })

      controller = Components.get_component(scope, controller.id)
      task = create_task(scope, controller)

      assert {:ok, :invalid, feedback} = DevelopController.evaluate(scope, task)
      assert feedback =~ "UserController"
      assert feedback =~ "spec_file"
    end

    test "returns :valid when no tracked requirements exist (vacuously satisfied)", %{tmp_dir: tmp_dir} do
      scope = create_scope_with_env(tmp_dir)
      controller = create_controller_component(scope)

      controller = Components.get_component(scope, controller.id)
      task = create_task(scope, controller)

      assert {:ok, :valid} = DevelopController.evaluate(scope, task)
    end
  end
end
