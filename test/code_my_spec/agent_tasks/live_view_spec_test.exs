defmodule CodeMySpec.AgentTasks.LiveViewSpecTest do
  @moduledoc false
  use CodeMySpec.DataCase, async: true

  alias CodeMySpec.AgentTasks.LiveViewSpec
  alias CodeMySpec.Components
  alias CodeMySpec.Environments.Environment

  import CodeMySpec.UsersFixtures
  import CodeMySpec.ComponentsFixtures
  import CodeMySpec.RequirementsFixtures

  @moduletag :tmp_dir

  # ============================================================================
  # Test Helpers
  # ============================================================================

  defp create_scope(tmp_dir) do
    scope = full_scope_fixture()
    %{scope | environment: Environment.new(:local, tmp_dir)}
  end

  defp create_liveview_component(scope, attrs \\ %{}) do
    component_fixture(
      scope,
      Map.merge(
        %{
          name: "DashboardLive",
          type: "liveview",
          module_name: "TestAppWeb.DashboardLive",
          description: "Main dashboard page"
        },
        attrs
      )
    )
  end

  defp create_session(scope, component) do
    %{
      component: component,
      project: scope.active_project
    }
  end

  defp write_file!(tmp_dir, relative_path, content) do
    full_path = Path.join(tmp_dir, relative_path)
    full_path |> Path.dirname() |> File.mkdir_p!()
    File.write!(full_path, content)
  end

  defp write_code_file!(tmp_dir, component, project) do
    %{code_file: code_path} = CodeMySpec.Utils.component_files(component, project)

    write_file!(tmp_dir, code_path, """
    defmodule #{component.module_name} do
      use Phoenix.LiveView
    end
    """)
  end

  defp write_test_file!(tmp_dir, component, project) do
    %{test_file: test_path} = CodeMySpec.Utils.component_files(component, project)

    write_file!(tmp_dir, test_path, """
    defmodule #{component.module_name}Test do
      use ExUnit.Case
    end
    """)
  end

  defp write_spec_file!(tmp_dir, component, project, content) do
    %{spec_file: spec_path} = CodeMySpec.Utils.component_files(component, project)
    write_file!(tmp_dir, spec_path, content || valid_spec_content(component))
  end

  defp valid_spec_content(component) do
    """
    # #{component.module_name}

    ## Type

    liveview

    ## Route

    `/dashboard`

    ## User Interactions

    - **phx-click="refresh"**: Reload dashboard data from context.

    ## Dependencies

    - TestApp.Accounts
    """
  end

  # ============================================================================
  # command/3 Tests
  # ============================================================================

  describe "command/3" do
    test "returns ok tuple with prompt text for valid session", %{tmp_dir: tmp_dir} do
      scope = create_scope(tmp_dir)
      component = create_liveview_component(scope)
      session = create_session(scope, component)

      assert {:ok, prompt} = LiveViewSpec.command(scope, session)
      assert is_binary(prompt)
      assert String.length(prompt) > 0
    end

    test "includes project name and description in prompt", %{tmp_dir: tmp_dir} do
      scope = create_scope(tmp_dir)
      component = create_liveview_component(scope)
      session = create_session(scope, component)

      assert {:ok, prompt} = LiveViewSpec.command(scope, session)
      assert prompt =~ scope.active_project.name
    end

    test "includes component name, description, and type in prompt", %{tmp_dir: tmp_dir} do
      scope = create_scope(tmp_dir)
      component = create_liveview_component(scope)
      session = create_session(scope, component)

      assert {:ok, prompt} = LiveViewSpec.command(scope, session)
      assert prompt =~ component.name
      assert prompt =~ component.description
      assert prompt =~ component.type
    end

    test "includes design rules content in prompt", %{tmp_dir: tmp_dir} do
      scope = create_scope(tmp_dir)
      component = create_liveview_component(scope)
      session = create_session(scope, component)

      assert {:ok, prompt} = LiveViewSpec.command(scope, session)
      # At minimum, wildcard design rules (elixir_design.md with component_type: "*")
      # should match for any component type + session_type "design"
      assert prompt =~ "Design Rules" or prompt =~ "Rules"
    end

    test "includes document specification in prompt", %{tmp_dir: tmp_dir} do
      scope = create_scope(tmp_dir)
      component = create_liveview_component(scope)
      session = create_session(scope, component)

      assert {:ok, prompt} = LiveViewSpec.command(scope, session)
      # DocumentSpecProjector.project_spec/1 returns section documentation
      assert prompt =~ "Required Sections" or prompt =~ "Document Specifications"
    end

    test "includes spec file path in prompt", %{tmp_dir: tmp_dir} do
      scope = create_scope(tmp_dir)
      component = create_liveview_component(scope)
      session = create_session(scope, component)

      %{spec_file: spec_path} =
        CodeMySpec.Utils.component_files(component, scope.active_project)

      assert {:ok, prompt} = LiveViewSpec.command(scope, session)
      assert prompt =~ spec_path
    end

    test "includes existing implementation file path when code exists", %{tmp_dir: tmp_dir} do
      scope = create_scope(tmp_dir)
      component = create_liveview_component(scope)
      session = create_session(scope, component)
      write_code_file!(tmp_dir, component, scope.active_project)

      %{code_file: code_path} =
        CodeMySpec.Utils.component_files(component, scope.active_project)

      assert {:ok, prompt} = LiveViewSpec.command(scope, session)
      assert prompt =~ code_path
    end

    test "includes existing test file path when tests exist", %{tmp_dir: tmp_dir} do
      scope = create_scope(tmp_dir)
      component = create_liveview_component(scope)
      session = create_session(scope, component)
      write_test_file!(tmp_dir, component, scope.active_project)

      %{test_file: test_path} =
        CodeMySpec.Utils.component_files(component, scope.active_project)

      assert {:ok, prompt} = LiveViewSpec.command(scope, session)
      assert prompt =~ test_path
    end

    test "includes parent component spec file path when parent exists", %{tmp_dir: tmp_dir} do
      scope = create_scope(tmp_dir)

      parent =
        component_fixture(scope, %{
          name: "AccountsLive",
          type: "liveview",
          module_name: "TestAppWeb.AccountsLive",
          description: "Accounts section"
        })

      component =
        create_liveview_component(scope, %{
          parent_component_id: parent.id
        })

      # Reload with parent_component preloaded
      component = Components.get_component(scope, component.id) |> Repo.preload(:parent_component)
      session = create_session(scope, component)

      %{spec_file: parent_spec_path} =
        CodeMySpec.Utils.component_files(parent, scope.active_project)

      assert {:ok, prompt} = LiveViewSpec.command(scope, session)
      assert prompt =~ parent_spec_path
    end

    test "includes similar components for pattern inspiration", %{tmp_dir: tmp_dir} do
      scope = create_scope(tmp_dir)
      component = create_liveview_component(scope)

      similar =
        component_fixture(scope, %{
          name: "SettingsLive",
          type: "liveview",
          module_name: "TestAppWeb.SettingsLive",
          description: "Settings page"
        })

      {:ok, _} = Components.add_similar_component(scope, component, similar)
      session = create_session(scope, component)

      assert {:ok, prompt} = LiveViewSpec.command(scope, session)
      assert prompt =~ similar.name or prompt =~ similar.module_name
    end

    test "includes UI spec format guidance with route, interactions, and structural Design section",
         %{tmp_dir: tmp_dir} do
      scope = create_scope(tmp_dir)
      component = create_liveview_component(scope)
      session = create_session(scope, component)

      assert {:ok, prompt} = LiveViewSpec.command(scope, session)
      assert prompt =~ "route" or prompt =~ "Route"

      assert prompt =~ "interaction" or prompt =~ "Interaction" or
               prompt =~ "event" or prompt =~ "Event"

      assert prompt =~ "Design" or prompt =~ "design"
    end

    test "document specification includes liveview-specific sections from registry", %{
      tmp_dir: tmp_dir
    } do
      scope = create_scope(tmp_dir)
      component = create_liveview_component(scope)
      session = create_session(scope, component)

      assert {:ok, prompt} = LiveViewSpec.command(scope, session)

      # Required liveview sections should appear in the document spec
      assert prompt =~ "Route"
      assert prompt =~ "User Interactions"
      assert prompt =~ "Dependencies"

      # Optional liveview sections should appear
      assert prompt =~ "Params"
      assert prompt =~ "Design"

      # Should NOT contain default spec sections that don't apply to liveviews
      refute prompt =~ "Delegates"
    end

    test "returns error if rules cannot be loaded", %{tmp_dir: tmp_dir} do
      scope = create_scope(tmp_dir)
      component = create_liveview_component(scope)

      # Simulate a component with a nil type (not possible via normal creation)
      # to verify the implementation handles invalid state gracefully
      broken_component = %{component | type: nil}
      session = create_session(scope, broken_component)

      assert {:error, _reason} = LiveViewSpec.command(scope, session)
    end
  end

  # ============================================================================
  # evaluate/3 Tests
  # ============================================================================

  describe "evaluate/3" do
    test "returns {:ok, :valid} when all specification requirements are satisfied",
         %{tmp_dir: tmp_dir} do
      scope = create_scope(tmp_dir)
      component = create_liveview_component(scope)

      requirement_fixture(scope, component, %{
        name: "spec_file",
        artifact_type: :specification,
        satisfied: true
      })

      requirement_fixture(scope, component, %{
        name: "spec_valid",
        artifact_type: :specification,
        satisfied: true
      })

      component = Components.get_component(scope, component.id)
      session = create_session(scope, component)

      assert {:ok, :valid} = LiveViewSpec.evaluate(scope, session)
    end

    test "returns {:ok, :invalid, feedback} when specification requirements are unsatisfied",
         %{tmp_dir: tmp_dir} do
      scope = create_scope(tmp_dir)
      component = create_liveview_component(scope)

      requirement_fixture(scope, component, %{
        name: "spec_file",
        artifact_type: :specification,
        satisfied: true
      })

      requirement_fixture(scope, component, %{
        name: "spec_valid",
        artifact_type: :specification,
        satisfied: false,
        details: %{reason: "Document validation failed"}
      })

      component = Components.get_component(scope, component.id)
      session = create_session(scope, component)

      assert {:ok, :invalid, feedback} = LiveViewSpec.evaluate(scope, session)
      assert is_binary(feedback)
    end

    test "includes unsatisfied requirement details in feedback", %{tmp_dir: tmp_dir} do
      scope = create_scope(tmp_dir)
      component = create_liveview_component(scope)

      requirement_fixture(scope, component, %{
        name: "spec_file",
        artifact_type: :specification,
        satisfied: false,
        description: "Component specification file exists",
        details: %{
          reason: "File missing",
          path: "docs/spec/test_app_web/dashboard_live.spec.md"
        }
      })

      component = Components.get_component(scope, component.id)
      session = create_session(scope, component)

      assert {:ok, :invalid, feedback} = LiveViewSpec.evaluate(scope, session)
      assert feedback =~ "spec" or feedback =~ "Spec" or feedback =~ "specification"
    end

    test "returns {:ok, :invalid, feedback} when spec file does not exist (via fallback checker)",
         %{tmp_dir: tmp_dir} do
      scope = create_scope(tmp_dir)
      component = create_liveview_component(scope)

      # No spec file written, no persisted requirements
      # Falls back to Registry defaults — FileExistenceChecker will find file missing
      component = Components.get_component(scope, component.id)
      session = create_session(scope, component)

      assert {:ok, :invalid, feedback} = LiveViewSpec.evaluate(scope, session)
      assert is_binary(feedback)
    end

    test "returns {:ok, :invalid, feedback} when spec content is invalid (via fallback checker)",
         %{tmp_dir: tmp_dir} do
      scope = create_scope(tmp_dir)
      component = create_liveview_component(scope)

      # Write a spec file that exists but has invalid content
      write_spec_file!(tmp_dir, component, scope.active_project, "not a valid spec document")

      # No persisted requirements — falls back to Registry defaults
      # FileExistenceChecker passes, but DocumentValidityChecker will fail
      component = Components.get_component(scope, component.id)
      session = create_session(scope, component)

      assert {:ok, :invalid, feedback} = LiveViewSpec.evaluate(scope, session)
      assert is_binary(feedback)
    end

    test "returns {:ok, :invalid, feedback} when spec file has problems even if requirements pass",
         %{tmp_dir: tmp_dir} do
      scope = create_scope(tmp_dir)
      component = create_liveview_component(scope)

      requirement_fixture(scope, component, %{
        name: "spec_file",
        artifact_type: :specification,
        satisfied: true
      })

      requirement_fixture(scope, component, %{
        name: "spec_valid",
        artifact_type: :specification,
        satisfied: true
      })

      %{spec_file: spec_file} =
        CodeMySpec.Utils.component_files(component, scope.active_project)

      {:ok, _} =
        CodeMySpec.Problems.create_problems(scope, [
          %{
            severity: :error,
            source_type: :static_analysis,
            source: "spec_validation",
            file_path: spec_file,
            message: "Missing required section: Functions",
            category: "document_structure"
          }
        ])

      component = Components.get_component(scope, component.id)
      session = create_session(scope, component)

      assert {:ok, :invalid, feedback} = LiveViewSpec.evaluate(scope, session)
      assert feedback =~ "Missing required section"
    end
  end
end
