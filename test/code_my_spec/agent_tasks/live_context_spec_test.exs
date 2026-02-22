defmodule CodeMySpec.AgentTasks.LiveContextSpecTest do
  use CodeMySpec.DataCase, async: true

  alias CodeMySpec.AgentTasks.LiveContextSpec
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

  defp create_live_context(scope) do
    component_fixture(scope, %{
      name: "UserLive",
      type: "live_context",
      module_name: "TestAppWeb.UserLive"
    })
  end

  defp create_spec_file!(tmp_dir, component, _project) do
    spec_path = "docs/spec/test_app_web/user_live.spec.md"
    full_path = Path.join(tmp_dir, spec_path)
    full_path |> Path.dirname() |> File.mkdir_p!()

    content = """
    # #{component.module_name}

    UI grouping for user management views and components.

    ## Type

    live_context

    ## LiveViews

    ### TestAppWeb.UserLive.Index

    - **Route:** `/users`
    - **Description:** Lists all users with search and pagination

    ### TestAppWeb.UserLive.Show

    - **Route:** `/users/:id`
    - **Description:** Displays a single user profile

    ## Components

    ### TestAppWeb.UserLive.FormComponent

    Form for creating and editing users.

    ## Dependencies

    - TestApp.Users
    """

    File.write!(full_path, content)
    full_path
  end

  # ============================================================================
  # command/3 Tests
  # ============================================================================

  describe "command/3" do
    test "generates prompt with live context details", %{tmp_dir: tmp_dir} do
      scope = create_scope_with_env(tmp_dir)
      live_context = create_live_context(scope)
      session = create_session(scope, live_context)

      assert {:ok, prompt} = LiveContextSpec.command(scope, session)
      assert prompt =~ "LiveContextSpec"
      assert prompt =~ "UserLive"
      assert prompt =~ "live context"
      assert prompt =~ "Live Context Spec"
    end

    test "includes project details in prompt", %{tmp_dir: tmp_dir} do
      scope = create_scope_with_env(tmp_dir)
      live_context = create_live_context(scope)
      session = create_session(scope, live_context)

      assert {:ok, prompt} = LiveContextSpec.command(scope, session)
      assert prompt =~ scope.active_project.name
    end
  end

  # ============================================================================
  # evaluate/3 Tests
  # ============================================================================

  describe "evaluate/3" do
    test "returns {:ok, :invalid} when spec file is missing", %{tmp_dir: tmp_dir} do
      scope = create_scope_with_env(tmp_dir)
      live_context = create_live_context(scope)
      session = create_session(scope, live_context)

      result = LiveContextSpec.evaluate(scope, session)
      assert {:ok, :invalid, _feedback} = result
    end

    test "returns {:ok, :valid} when spec file exists and is valid", %{tmp_dir: tmp_dir} do
      scope = create_scope_with_env(tmp_dir)
      live_context = create_live_context(scope)

      # Create spec file
      create_spec_file!(tmp_dir, live_context, scope.active_project)

      # Mark requirements as satisfied
      requirement_fixture(scope, live_context, %{
        name: "spec_file",
        artifact_type: :specification,
        satisfied: true
      })

      requirement_fixture(scope, live_context, %{
        name: "spec_valid",
        artifact_type: :specification,
        satisfied: true
      })

      session = create_session(scope, live_context)

      assert {:ok, :valid} = LiveContextSpec.evaluate(scope, session)
    end

    test "creates child spec stubs from LiveViews and Components sections on valid", %{
      tmp_dir: tmp_dir
    } do
      scope = create_scope_with_env(tmp_dir)
      live_context = create_live_context(scope)

      create_spec_file!(tmp_dir, live_context, scope.active_project)

      requirement_fixture(scope, live_context, %{
        name: "spec_file",
        artifact_type: :specification,
        satisfied: true
      })

      requirement_fixture(scope, live_context, %{
        name: "spec_valid",
        artifact_type: :specification,
        satisfied: true
      })

      session = create_session(scope, live_context)

      assert {:ok, :valid} = LiveContextSpec.evaluate(scope, session)

      # Check that child spec stubs were created
      index_stub = Path.join(tmp_dir, "docs/spec/test_app_web/user_live/index.spec.md")
      show_stub = Path.join(tmp_dir, "docs/spec/test_app_web/user_live/show.spec.md")
      form_stub = Path.join(tmp_dir, "docs/spec/test_app_web/user_live/form_component.spec.md")

      assert File.exists?(index_stub), "Expected Index child stub at #{index_stub}"
      assert File.exists?(show_stub), "Expected Show child stub at #{show_stub}"
      assert File.exists?(form_stub), "Expected FormComponent child stub at #{form_stub}"
    end

    test "does not overwrite existing child spec files", %{tmp_dir: tmp_dir} do
      scope = create_scope_with_env(tmp_dir)
      live_context = create_live_context(scope)

      create_spec_file!(tmp_dir, live_context, scope.active_project)

      # Pre-create a child spec with custom content
      index_path = Path.join(tmp_dir, "docs/spec/test_app_web/user_live/index.spec.md")
      index_path |> Path.dirname() |> File.mkdir_p!()
      File.write!(index_path, "# Custom content\nDo not overwrite")

      requirement_fixture(scope, live_context, %{
        name: "spec_file",
        artifact_type: :specification,
        satisfied: true
      })

      requirement_fixture(scope, live_context, %{
        name: "spec_valid",
        artifact_type: :specification,
        satisfied: true
      })

      session = create_session(scope, live_context)

      assert {:ok, :valid} = LiveContextSpec.evaluate(scope, session)

      # Existing file should not be overwritten
      assert File.read!(index_path) =~ "Custom content"
    end
  end
end
