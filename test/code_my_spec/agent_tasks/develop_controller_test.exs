defmodule CodeMySpec.AgentTasks.DevelopControllerTest do
  use CodeMySpec.DataCase, async: true

  alias CodeMySpec.AgentTasks.DevelopController
  alias CodeMySpec.Components
  alias CodeMySpec.Environments.Environment

  import CodeMySpec.UsersFixtures
  import CodeMySpec.ComponentsFixtures
  import CodeMySpec.RequirementsFixtures

  @moduletag :tmp_dir

  # ============================================================================
  # Test Helpers
  # ============================================================================

  defp create_scope_with_env(tmp_dir) do
    scope = full_scope_fixture()
    %{scope | environment: Environment.new(:local, tmp_dir)}
  end

  defp create_session(scope, controller_component) do
    %{
      component: controller_component,
      project: scope.active_project,
      external_conversation_id: "test-session-#{System.unique_integer([:positive])}"
    }
  end

  defp create_controller_component(scope) do
    component_fixture(scope, %{
      name: "UserController",
      type: "controller",
      module_name: "TestAppWeb.UserController"
    })
  end

  defp create_spec_file!(tmp_dir, component, project) do
    spec_path = CodeMySpec.Utils.component_files(component, project).spec_file
    full_path = Path.join(tmp_dir, spec_path)
    full_path |> Path.dirname() |> File.mkdir_p!()

    content = """
    # #{component.module_name}

    ## Functions

    - `index/2` - Lists all users
    - `show/2` - Shows a single user
    - `create/2` - Creates a new user

    ## Dependencies

    None
    """

    File.write!(full_path, content)
    full_path
  end

  defp create_satisfied_requirements!(scope, component, artifact_type) do
    requirement_fixture(scope, component, %{
      name: "#{artifact_type}_requirement",
      artifact_type: artifact_type,
      satisfied: true
    })
  end

  defp controller_status_dir(module_name) do
    parts =
      module_name
      |> String.split(".")
      |> Enum.map(&Macro.underscore/1)

    {dir_parts, [dirname]} = Enum.split(parts, -1)
    Path.join([".code_my_spec/status" | dir_parts] ++ [dirname])
  end

  defp read_orchestration_file(tmp_dir, module_name) do
    Path.join(tmp_dir, "#{controller_status_dir(module_name)}/develop_controller.md")
    |> File.read!()
  end

  # ============================================================================
  # command/3 Tests
  # ============================================================================

  describe "command/3" do
    test "returns completion message when all phases are complete", %{tmp_dir: tmp_dir} do
      scope = create_scope_with_env(tmp_dir)
      controller = create_controller_component(scope)

      create_spec_file!(tmp_dir, controller, scope.active_project)

      create_satisfied_requirements!(scope, controller, :tests)
      create_satisfied_requirements!(scope, controller, :code)

      controller = Components.get_component(scope, controller.id)
      session = create_session(scope, controller)

      assert {:ok, _message} = DevelopController.command(scope, session)
      content = read_orchestration_file(tmp_dir, controller.module_name)
      assert content =~ "Controller lifecycle is complete"
      assert content =~ "No further action required"
    end

    test "generates controller spec prompt when spec is missing", %{tmp_dir: tmp_dir} do
      scope = create_scope_with_env(tmp_dir)
      controller = create_controller_component(scope)
      session = create_session(scope, controller)

      assert {:ok, _message} = DevelopController.command(scope, session)
      content = read_orchestration_file(tmp_dir, controller.module_name)
      assert content =~ "Controller Specification"
      assert content =~ "Controller Lifecycle"

      status_dir = controller_status_dir(controller.module_name)
      safe_name = controller.module_name |> String.replace(".", "_") |> String.downcase()
      prompt_path = Path.join(tmp_dir, "#{status_dir}/#{safe_name}_controller_spec.md")
      assert File.exists?(prompt_path)
    end

    test "generates implementation prompts when spec is complete", %{tmp_dir: tmp_dir} do
      scope = create_scope_with_env(tmp_dir)
      controller = create_controller_component(scope)

      create_spec_file!(tmp_dir, controller, scope.active_project)

      requirement_fixture(scope, controller, %{
        name: "tests_requirement",
        artifact_type: :tests,
        satisfied: false
      })

      requirement_fixture(scope, controller, %{
        name: "code_requirement",
        artifact_type: :code,
        satisfied: false
      })

      controller = Components.get_component(scope, controller.id)
      session = create_session(scope, controller)

      assert {:ok, _message} = DevelopController.command(scope, session)
      content = read_orchestration_file(tmp_dir, controller.module_name)
      assert content =~ "Implementation"

      status_dir = controller_status_dir(controller.module_name)
      safe_name = controller.module_name |> String.replace(".", "_") |> String.downcase()

      test_path = Path.join(tmp_dir, "#{status_dir}/#{safe_name}_test.md")
      assert File.exists?(test_path), "Expected test prompt for controller"

      code_path = Path.join(tmp_dir, "#{status_dir}/#{safe_name}_code.md")
      assert File.exists?(code_path), "Expected code prompt for controller"
    end

    test "uses controller-specific terminology, not context terminology", %{tmp_dir: tmp_dir} do
      scope = create_scope_with_env(tmp_dir)
      controller = create_controller_component(scope)
      session = create_session(scope, controller)

      assert {:ok, _message} = DevelopController.command(scope, session)
      content = read_orchestration_file(tmp_dir, controller.module_name)

      assert content =~ "Controller Lifecycle"
      refute content =~ "Context Lifecycle"
      refute content =~ "bounded context"
      refute content =~ "Design Review"
    end

    test "generates JSON view stub spec on command", %{tmp_dir: tmp_dir} do
      scope = create_scope_with_env(tmp_dir)
      controller = create_controller_component(scope)
      session = create_session(scope, controller)

      # JSON stub spec should not exist yet
      json_spec_path = Path.join(tmp_dir, ".code_my_spec/spec/test_app_web/user_json.spec.md")
      refute File.exists?(json_spec_path)

      assert {:ok, _message} = DevelopController.command(scope, session)

      # After command, stub spec should exist with type "json"
      assert File.exists?(json_spec_path)
      content = File.read!(json_spec_path)
      assert content =~ "TestAppWeb.UserJSON"
      assert content =~ "## Type"
      assert content =~ "json"
      assert content =~ "companion for TestAppWeb.UserController"
    end

    test "does not overwrite existing JSON view spec", %{tmp_dir: tmp_dir} do
      scope = create_scope_with_env(tmp_dir)
      controller = create_controller_component(scope)
      session = create_session(scope, controller)

      # Write a custom spec first
      json_spec_path = Path.join(tmp_dir, ".code_my_spec/spec/test_app_web/user_json.spec.md")
      json_spec_path |> Path.dirname() |> File.mkdir_p!()
      File.write!(json_spec_path, "# Custom spec\n\nCustom content")

      assert {:ok, _message} = DevelopController.command(scope, session)

      # Should not overwrite
      assert File.read!(json_spec_path) =~ "Custom content"
    end

    test "writes prompt files to .code_my_spec/status/ directory structure", %{tmp_dir: tmp_dir} do
      scope = create_scope_with_env(tmp_dir)
      controller = create_controller_component(scope)
      session = create_session(scope, controller)

      assert {:ok, _prompt} = DevelopController.command(scope, session)

      expected_dir = Path.join(tmp_dir, controller_status_dir(controller.module_name))
      assert File.exists?(expected_dir)
      assert File.dir?(expected_dir)
    end
  end

  # ============================================================================
  # evaluate/3 Tests
  # ============================================================================

  describe "evaluate/3" do
    test "returns {:ok, :valid} when all phases are complete", %{tmp_dir: tmp_dir} do
      scope = create_scope_with_env(tmp_dir)
      controller = create_controller_component(scope)

      create_spec_file!(tmp_dir, controller, scope.active_project)

      create_satisfied_requirements!(scope, controller, :tests)
      create_satisfied_requirements!(scope, controller, :code)

      controller = Components.get_component(scope, controller.id)
      session = create_session(scope, controller)

      assert {:ok, :valid} = DevelopController.evaluate(scope, session)
    end

    test "returns {:ok, :invalid, feedback} when phases are incomplete", %{tmp_dir: tmp_dir} do
      scope = create_scope_with_env(tmp_dir)
      controller = create_controller_component(scope)
      session = create_session(scope, controller)

      assert {:ok, :invalid, feedback} = DevelopController.evaluate(scope, session)
      assert is_binary(feedback)
    end

    test "feedback includes incomplete phase names and controller name", %{tmp_dir: tmp_dir} do
      scope = create_scope_with_env(tmp_dir)
      controller = create_controller_component(scope)
      session = create_session(scope, controller)

      assert {:ok, :invalid, feedback} = DevelopController.evaluate(scope, session)
      assert feedback =~ "Controller Specification"
      assert feedback =~ "incomplete phases"
      assert feedback =~ controller.name
    end

    test "cleans up spec prompt files when spec phase completes", %{tmp_dir: tmp_dir} do
      scope = create_scope_with_env(tmp_dir)
      controller = create_controller_component(scope)

      # Initially no spec — command generates spec prompt
      session = create_session(scope, controller)
      assert {:ok, _message} = DevelopController.command(scope, session)

      status_dir = controller_status_dir(controller.module_name)
      safe_name = controller.module_name |> String.replace(".", "_") |> String.downcase()
      spec_prompt = Path.join(tmp_dir, "#{status_dir}/#{safe_name}_controller_spec.md")
      assert File.exists?(spec_prompt)

      # Now create the spec file to complete that phase
      create_spec_file!(tmp_dir, controller, scope.active_project)

      controller = Components.get_component(scope, controller.id)
      session = create_session(scope, controller)

      result = DevelopController.evaluate(scope, session)

      case result do
        {:ok, :valid} -> assert true
        {:ok, :invalid, _feedback} -> assert true
        other -> flunk("Unexpected result: #{inspect(other)}")
      end

      refute File.exists?(spec_prompt),
             "Controller spec prompt should be cleaned up after phase completes"
    end

    test "removes status directory when all phases complete", %{tmp_dir: tmp_dir} do
      scope = create_scope_with_env(tmp_dir)
      controller = create_controller_component(scope)

      create_spec_file!(tmp_dir, controller, scope.active_project)

      create_satisfied_requirements!(scope, controller, :tests)
      create_satisfied_requirements!(scope, controller, :code)

      # Create status directory with a leftover file
      status_dir_path = Path.join(tmp_dir, controller_status_dir(controller.module_name))
      File.mkdir_p!(status_dir_path)
      File.write!(Path.join(status_dir_path, "develop_controller.md"), "old content")

      controller = Components.get_component(scope, controller.id)
      session = create_session(scope, controller)

      assert {:ok, :valid} = DevelopController.evaluate(scope, session)

      refute File.exists?(status_dir_path),
             "Status directory should be removed when all phases complete"
    end
  end
end
