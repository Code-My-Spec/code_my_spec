defmodule CodeMySpec.AgentTasks.DevelopLiveContextTest do
  use CodeMySpecTest.DataCase, async: true

  alias CodeMySpec.AgentTasks.DevelopLiveContext
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

  defp create_session(scope, component) do
    %{
      component: component,
      project: scope.active_project,
      external_conversation_id: "test-session-#{System.unique_integer([:positive])}"
    }
  end

  defp create_live_context_with_children(scope) do
    live_context =
      component_fixture(scope, %{
        name: "UserLive",
        type: "live_context",
        module_name: "TestAppWeb.UserLive"
      })

    child_liveview =
      component_fixture(scope, %{
        name: "Index",
        type: "liveview",
        module_name: "TestAppWeb.UserLive.Index",
        parent_component_id: live_context.id
      })

    child_component =
      component_fixture(scope, %{
        name: "FormComponent",
        type: "liveview_component",
        module_name: "TestAppWeb.UserLive.FormComponent",
        parent_component_id: live_context.id
      })

    {live_context, [child_liveview, child_component]}
  end

  defp create_spec_file!(tmp_dir, component, _project) do
    module_path =
      component.module_name
      |> String.split(".")
      |> Enum.map(&Macro.underscore/1)
      |> Path.join()

    spec_path = ".code_my_spec/spec/#{module_path}.spec.md"
    full_path = Path.join(tmp_dir, spec_path)
    full_path |> Path.dirname() |> File.mkdir_p!()
    content = valid_spec_content(component)
    File.write!(full_path, content)
    full_path
  end

  defp valid_spec_content(%{type: "live_context"} = component) do
    """
    # #{component.module_name}

    UI grouping for user management.

    ## Type

    live_context

    ## LiveViews

    ### TestAppWeb.UserLive.Index

    - **Route:** `/users`
    - **Description:** Lists all users

    ## Components

    ### TestAppWeb.UserLive.FormComponent

    Form for creating and editing users.

    ## Dependencies

    - TestApp.Users
    """
  end

  defp valid_spec_content(%{type: "liveview"} = component) do
    """
    # #{component.module_name}

    ## Route

    `/users`

    ## User Interactions

    - `refresh` → Reload data

    ## Dependencies

    - TestApp.Users

    ## Design

    Layout: Full-width list with search
    """
  end

  defp valid_spec_content(%{type: "liveview_component"} = component) do
    """
    # #{component.module_name}

    ## Assigns

    | Assign | Type | Required | Description |
    | ------ | ---- | -------- | ----------- |
    | id     | any  | Yes      | Component ID |

    ## Design

    Layout: Form with validation
    """
  end

  defp valid_spec_content(component) do
    """
    # #{component.module_name}

    ## Functions

    - `render/1` - Renders the component

    ## Dependencies

    None
    """
  end

  defp create_satisfied_requirements!(scope, component, artifact_type) do
    requirement_fixture(scope, component, %{
      name: "#{artifact_type}_requirement",
      artifact_type: artifact_type,
      satisfied: true
    })
  end

  defp live_context_status_dir(module_name) do
    parts =
      module_name
      |> String.split(".")
      |> Enum.map(&Macro.underscore/1)

    {dir_parts, [dirname]} = Enum.split(parts, -1)
    Path.join([".code_my_spec/status" | dir_parts] ++ [dirname])
  end

  defp read_orchestration_file(tmp_dir, module_name) do
    Path.join(tmp_dir, "#{live_context_status_dir(module_name)}/develop_live_context.md")
    |> File.read!()
  end

  defp safe_filename(module_name) do
    module_name
    |> String.replace(".", "_")
    |> String.downcase()
  end

  # ============================================================================
  # command/3 Tests
  # ============================================================================

  describe "command/3" do
    test "returns completion message when all phases are complete", %{tmp_dir: tmp_dir} do
      scope = create_scope_with_env(tmp_dir)
      {live_context, children} = create_live_context_with_children(scope)

      # Create all spec files
      create_spec_file!(tmp_dir, live_context, scope.active_project)

      for child <- children do
        create_spec_file!(tmp_dir, child, scope.active_project)
      end

      # Mark all requirements as satisfied
      for component <- [live_context | children] do
        create_satisfied_requirements!(scope, component, :specification)
      end

      # Children need implementation satisfied too
      for child <- children do
        create_satisfied_requirements!(scope, child, :tests)
        create_satisfied_requirements!(scope, child, :code)
      end

      live_context = Components.get_component(scope, live_context.id)
      session = create_session(scope, live_context)

      assert {:ok, _message} = DevelopLiveContext.command(scope, session)
      content = read_orchestration_file(tmp_dir, live_context.module_name)
      assert content =~ "complete"
      assert content =~ "No further action required"
    end

    test "generates live context spec prompt when spec is missing", %{tmp_dir: tmp_dir} do
      scope = create_scope_with_env(tmp_dir)
      {live_context, _children} = create_live_context_with_children(scope)
      session = create_session(scope, live_context)

      assert {:ok, _message} = DevelopLiveContext.command(scope, session)
      content = read_orchestration_file(tmp_dir, live_context.module_name)
      assert content =~ "Live Context" or content =~ "Spec"

      # Verify prompt file was created
      status_dir = live_context_status_dir(live_context.module_name)
      safe_name = safe_filename(live_context.module_name)
      prompt_path = Path.join(tmp_dir, "#{status_dir}/#{safe_name}_live_context_spec.md")
      assert File.exists?(prompt_path)
    end

    test "generates child spec prompts when child specs are missing", %{tmp_dir: tmp_dir} do
      scope = create_scope_with_env(tmp_dir)
      {live_context, children} = create_live_context_with_children(scope)

      # Create parent spec but not child specs
      create_spec_file!(tmp_dir, live_context, scope.active_project)
      create_satisfied_requirements!(scope, live_context, :specification)

      session = create_session(scope, live_context)

      assert {:ok, _message} = DevelopLiveContext.command(scope, session)

      status_dir = live_context_status_dir(live_context.module_name)

      for child <- children do
        safe_name = safe_filename(child.module_name)
        prompt_path = Path.join(tmp_dir, "#{status_dir}/#{safe_name}_child_spec.md")
        assert File.exists?(prompt_path), "Expected child spec prompt for #{child.name}"
      end
    end

    test "parent live_context is NOT included in implementation phase", %{tmp_dir: tmp_dir} do
      scope = create_scope_with_env(tmp_dir)
      {live_context, children} = create_live_context_with_children(scope)

      # Complete spec phases
      create_spec_file!(tmp_dir, live_context, scope.active_project)

      for child <- children do
        create_spec_file!(tmp_dir, child, scope.active_project)
      end

      for component <- [live_context | children] do
        create_satisfied_requirements!(scope, component, :specification)
      end

      # Create unsatisfied implementation requirements for children only
      for child <- children do
        requirement_fixture(scope, child, %{
          name: "tests_requirement",
          artifact_type: :tests,
          satisfied: false
        })
      end

      live_context = Components.get_component(scope, live_context.id)
      session = create_session(scope, live_context)

      assert {:ok, _message} = DevelopLiveContext.command(scope, session)

      status_dir = live_context_status_dir(live_context.module_name)

      # Parent should NOT have implementation prompt files
      parent_safe = safe_filename(live_context.module_name)
      parent_test = Path.join(tmp_dir, "#{status_dir}/#{parent_safe}_test.md")
      parent_code = Path.join(tmp_dir, "#{status_dir}/#{parent_safe}_code.md")

      refute File.exists?(parent_test),
             "Parent live_context should NOT have a test prompt"

      refute File.exists?(parent_code),
             "Parent live_context should NOT have a code prompt"

      # But children SHOULD have implementation prompt files
      for child <- children do
        child_safe = safe_filename(child.module_name)
        child_test = Path.join(tmp_dir, "#{status_dir}/#{child_safe}_test.md")
        assert File.exists?(child_test), "Child #{child.name} should have test prompt"
      end
    end

    test "implementation phase orders LiveComponents before LiveViews", %{tmp_dir: tmp_dir} do
      scope = create_scope_with_env(tmp_dir)
      {live_context, children} = create_live_context_with_children(scope)

      # Complete spec phases
      create_spec_file!(tmp_dir, live_context, scope.active_project)

      for child <- children do
        create_spec_file!(tmp_dir, child, scope.active_project)
      end

      for component <- [live_context | children] do
        create_satisfied_requirements!(scope, component, :specification)
      end

      for child <- children do
        requirement_fixture(scope, child, %{
          name: "tests_requirement",
          artifact_type: :tests,
          satisfied: false
        })

        requirement_fixture(scope, child, %{
          name: "code_requirement",
          artifact_type: :code,
          satisfied: false
        })
      end

      live_context = Components.get_component(scope, live_context.id)
      session = create_session(scope, live_context)

      assert {:ok, _message} = DevelopLiveContext.command(scope, session)
      content = read_orchestration_file(tmp_dir, live_context.module_name)

      # Should mention implementation order
      assert content =~ "LiveComponent"
      assert content =~ "LiveView"
    end
  end

  # ============================================================================
  # evaluate/3 Tests
  # ============================================================================

  describe "evaluate/3" do
    test "returns {:ok, :valid} when all phases are complete", %{tmp_dir: tmp_dir} do
      scope = create_scope_with_env(tmp_dir)
      {live_context, children} = create_live_context_with_children(scope)

      create_spec_file!(tmp_dir, live_context, scope.active_project)

      for child <- children do
        create_spec_file!(tmp_dir, child, scope.active_project)
      end

      for component <- [live_context | children] do
        create_satisfied_requirements!(scope, component, :specification)
      end

      for child <- children do
        create_satisfied_requirements!(scope, child, :tests)
        create_satisfied_requirements!(scope, child, :code)
      end

      live_context = Components.get_component(scope, live_context.id)
      session = create_session(scope, live_context)

      assert {:ok, :valid} = DevelopLiveContext.evaluate(scope, session)
    end

    test "returns {:ok, :invalid, feedback} when spec phase is incomplete", %{tmp_dir: tmp_dir} do
      scope = create_scope_with_env(tmp_dir)
      {live_context, _children} = create_live_context_with_children(scope)
      session = create_session(scope, live_context)

      assert {:ok, :invalid, feedback} = DevelopLiveContext.evaluate(scope, session)
      assert is_binary(feedback)
      assert feedback =~ "incomplete phases" or feedback =~ "incomplete"
    end

    test "returns {:ok, :invalid, feedback} when implementation phase is incomplete", %{
      tmp_dir: tmp_dir
    } do
      scope = create_scope_with_env(tmp_dir)
      {live_context, children} = create_live_context_with_children(scope)

      # Complete spec phases
      create_spec_file!(tmp_dir, live_context, scope.active_project)

      for child <- children do
        create_spec_file!(tmp_dir, child, scope.active_project)
      end

      for component <- [live_context | children] do
        create_satisfied_requirements!(scope, component, :specification)
      end

      # Create unsatisfied implementation requirements for children
      for child <- children do
        requirement_fixture(scope, child, %{
          name: "tests_requirement",
          artifact_type: :tests,
          satisfied: false
        })
      end

      live_context = Components.get_component(scope, live_context.id)
      session = create_session(scope, live_context)

      assert {:ok, :invalid, feedback} = DevelopLiveContext.evaluate(scope, session)
      assert is_binary(feedback)
    end

    test "removes status directory when all phases complete", %{tmp_dir: tmp_dir} do
      scope = create_scope_with_env(tmp_dir)
      {live_context, children} = create_live_context_with_children(scope)

      create_spec_file!(tmp_dir, live_context, scope.active_project)

      for child <- children do
        create_spec_file!(tmp_dir, child, scope.active_project)
      end

      for component <- [live_context | children] do
        create_satisfied_requirements!(scope, component, :specification)
      end

      for child <- children do
        create_satisfied_requirements!(scope, child, :tests)
        create_satisfied_requirements!(scope, child, :code)
      end

      # Create status directory with leftover file
      status_dir_path = Path.join(tmp_dir, live_context_status_dir(live_context.module_name))
      File.mkdir_p!(status_dir_path)
      File.write!(Path.join(status_dir_path, "develop_live_context.md"), "old content")

      live_context = Components.get_component(scope, live_context.id)
      session = create_session(scope, live_context)

      assert {:ok, :valid} = DevelopLiveContext.evaluate(scope, session)

      refute File.exists?(status_dir_path),
             "Status directory should be removed when all phases complete"
    end
  end
end
