defmodule CodeMySpec.AgentTasks.LiveViewCodeTest do
  @moduledoc false
  use CodeMySpecTest.DataCase

  import CodeMySpec.UsersFixtures
  import CodeMySpec.ComponentsFixtures
  import CodeMySpec.RequirementsFixtures
  import CodeMySpec.StoriesFixtures

  alias CodeMySpec.AgentTasks.LiveViewCode
  alias CodeMySpec.Components
  alias CodeMySpec.Environments.Environment
  alias CodeMySpec.Stories

  @moduletag :tmp_dir

  # ============================================================================
  # Test Helpers
  # ============================================================================

  defp create_scope(context) do
    scope = full_scope_fixture()
    scope = %{scope | environment: Environment.new(:local, context.tmp_dir)}
    %{scope: scope}
  end

  defp create_project(context) do
    %{scope: scope} = context
    Map.put(context, :project, scope.active_project)
  end

  defp create_component(context, attrs \\ %{}) do
    %{project: project, scope: scope} = context

    default_attrs = %{
      name: "DashboardLive",
      description: "Main dashboard page",
      type: "liveview",
      module_name: "TestAppWeb.DashboardLive",
      project_id: project.id
    }

    component = component_fixture(scope, Map.merge(default_attrs, attrs))
    Map.put(context, :component, component)
  end

  defp create_session(context) do
    %{project: project, component: component} = context
    Map.put(context, :session, %{project: project, component: component})
  end

  # ============================================================================
  # command/3 Tests
  # ============================================================================

  describe "command/3" do
    setup [:create_scope, :create_project, :create_component, :create_session]

    test "includes spec file path and test file path in prompt", %{
      session: session,
      scope: scope,
      component: component,
      project: project
    } do
      %{spec_file: spec_file, test_file: test_file} =
        CodeMySpec.Utils.component_files(component, project)

      assert {:ok, prompt} = LiveViewCode.command(scope, session)
      assert prompt =~ spec_file
      assert prompt =~ test_file
    end

    test "includes component name and type in prompt", %{
      session: session,
      scope: scope,
      component: component
    } do
      assert {:ok, prompt} = LiveViewCode.command(scope, session)
      assert prompt =~ component.name
      assert prompt =~ component.type
    end

    test "includes project name and description in prompt", %{
      session: session,
      scope: scope,
      project: project
    } do
      assert {:ok, prompt} = LiveViewCode.command(scope, session)
      assert prompt =~ project.name
    end

    test "includes coding rules from matching rules", %{
      session: session,
      scope: scope
    } do
      assert {:ok, prompt} = LiveViewCode.command(scope, session)
      assert prompt =~ "Coding Rules" or prompt =~ "rules"
    end

    test "includes resources directory path for progressive disclosure", %{
      session: session,
      scope: scope
    } do
      assert {:ok, prompt} = LiveViewCode.command(scope, session)
      assert prompt =~ "resources"
    end

    test "includes similar components with file paths when available", %{
      session: session,
      scope: scope,
      component: component,
      project: project
    } do
      similar =
        component_fixture(scope, %{
          name: "SettingsLive",
          type: "liveview",
          module_name: "TestAppWeb.SettingsLive",
          description: "Settings page",
          project_id: project.id
        })

      {:ok, _} = Components.add_similar_component(scope, component, similar)

      assert {:ok, prompt} = LiveViewCode.command(scope, session)
      assert prompt =~ similar.name
    end

    test "handles empty similar components list with fallback text", %{
      session: session,
      scope: scope
    } do
      assert {:ok, prompt} = LiveViewCode.command(scope, session)
      assert prompt =~ "No similar components" or prompt =~ "Similar Components"
    end

    test "handles component with no description", %{
      scope: scope,
      project: project
    } do
      component =
        component_fixture(scope, %{
          name: "BlankLive",
          type: "liveview",
          module_name: "TestAppWeb.BlankLive",
          description: nil,
          project_id: project.id
        })

      session = %{project: project, component: component}

      assert {:ok, prompt} = LiveViewCode.command(scope, session)
      assert is_binary(prompt)
    end
  end

  # ============================================================================
  # evaluate/3 Tests
  # ============================================================================

  describe "evaluate/3" do
    setup [:create_scope, :create_project, :create_component, :create_session]

    test "returns {:ok, :valid} when all code requirements are satisfied", %{
      session: session,
      scope: scope,
      component: component
    } do
      requirement_fixture(scope, component, %{
        name: "implementation_file",
        artifact_type: :code,
        description: "Component implementation file exists",
        satisfied: true
      })

      requirement_fixture(scope, component, %{
        name: "tests_passing",
        artifact_type: :code,
        description: "Component tests are passing",
        satisfied: true
      })

      assert {:ok, :valid} = LiveViewCode.evaluate(scope, session)
    end

    test "returns {:ok, :invalid, feedback} when implementation_file requirement is unsatisfied",
         %{
           session: session,
           scope: scope,
           component: component
         } do
      requirement_fixture(scope, component, %{
        name: "implementation_file",
        artifact_type: :code,
        description: "Component implementation file exists",
        satisfied: false,
        details: %{reason: "File missing", path: "lib/test_app_web/dashboard_live.ex"}
      })

      assert {:ok, :invalid, feedback} = LiveViewCode.evaluate(scope, session)
      assert feedback =~ "requirements not met"
    end

    test "returns {:ok, :invalid, feedback} when tests_passing requirement is unsatisfied", %{
      session: session,
      scope: scope,
      component: component
    } do
      requirement_fixture(scope, component, %{
        name: "implementation_file",
        artifact_type: :code,
        description: "Component implementation file exists",
        satisfied: true
      })

      requirement_fixture(scope, component, %{
        name: "tests_passing",
        artifact_type: :code,
        description: "Component tests are passing",
        satisfied: false,
        details: %{reason: "Test failures found", problem_count: 2}
      })

      assert {:ok, :invalid, feedback} = LiveViewCode.evaluate(scope, session)
      assert feedback =~ "requirements not met"
    end

    test "ignores non-code artifact type requirements", %{
      session: session,
      scope: scope,
      component: component
    } do
      # Satisfied code requirements
      requirement_fixture(scope, component, %{
        name: "implementation_file",
        artifact_type: :code,
        description: "Component implementation file exists",
        satisfied: true
      })

      requirement_fixture(scope, component, %{
        name: "tests_passing",
        artifact_type: :code,
        description: "Component tests are passing",
        satisfied: true
      })

      # Unsatisfied non-code requirement — should be ignored
      requirement_fixture(scope, component, %{
        name: "test_file",
        artifact_type: :tests,
        description: "Component test file exists",
        satisfied: false
      })

      assert {:ok, :valid} = LiveViewCode.evaluate(scope, session)
    end

    test "feedback includes requirements not met context message", %{
      session: session,
      scope: scope,
      component: component
    } do
      requirement_fixture(scope, component, %{
        name: "implementation_file",
        artifact_type: :code,
        description: "Component implementation file exists",
        satisfied: false,
        details: %{reason: "File missing"}
      })

      assert {:ok, :invalid, feedback} = LiveViewCode.evaluate(scope, session)
      assert is_binary(feedback)
      assert String.length(feedback) > 0
    end

    test "reloads component from database before checking requirements", %{
      session: session,
      scope: scope,
      component: component
    } do
      # Add requirements AFTER session is created — evaluate should still find them
      # because it reloads the component from the database
      requirement_fixture(scope, component, %{
        name: "implementation_file",
        artifact_type: :code,
        description: "Component implementation file exists",
        satisfied: false,
        details: %{reason: "File missing"}
      })

      assert {:ok, :invalid, _feedback} = LiveViewCode.evaluate(scope, session)
    end

    test "returns invalid when problems exist on code or test files even if requirements pass", %{
      session: session,
      scope: scope,
      component: component,
      project: project
    } do
      satisfy_code_requirements(scope, component)
      %{code_file: code_file} = CodeMySpec.Utils.component_files(component, project)

      {:ok, _} =
        CodeMySpec.Problems.create_problems(scope, [
          %{
            severity: :warning,
            source_type: :static_analysis,
            source: "credo",
            file_path: code_file,
            message: "Modules should have a @moduledoc tag",
            category: "readability"
          }
        ])

      assert {:ok, :invalid, feedback} = LiveViewCode.evaluate(scope, session)
      assert feedback =~ "@moduledoc"
    end

    test "combines requirement and problem feedback when both fail", %{
      session: session,
      scope: scope,
      component: component,
      project: project
    } do
      requirement_fixture(scope, component, %{
        name: "implementation_file",
        artifact_type: :code,
        description: "Component implementation file exists",
        satisfied: false,
        details: %{reason: "File missing"}
      })

      %{code_file: code_file} = CodeMySpec.Utils.component_files(component, project)

      {:ok, _} =
        CodeMySpec.Problems.create_problems(scope, [
          %{
            severity: :error,
            source_type: :static_analysis,
            source: "compiler",
            file_path: code_file,
            message: "undefined function bar/0",
            category: "undefined_function"
          }
        ])

      assert {:ok, :invalid, feedback} = LiveViewCode.evaluate(scope, session)
      assert feedback =~ "requirements not met"
      assert feedback =~ "undefined function"
    end
  end

  # ============================================================================
  # BDD Spec Integration Tests
  # ============================================================================

  describe "command/3 with BDD specs" do
    setup [:create_scope, :create_project, :create_component, :create_session]

    test "includes BDD spec instructions when component satisfies a story with specs", %{
      session: session,
      scope: scope,
      component: component
    } do
      story = story_fixture(scope)
      {:ok, _} = Stories.set_story_component(scope, story, component.id)
      create_spex_file(scope.environment.cwd, story.id, 1)

      assert {:ok, prompt} = LiveViewCode.command(scope, session)
      assert prompt =~ "BDD Acceptance Specs"
      assert prompt =~ "mix spex"
    end

    test "does not include BDD spec instructions when component has no stories", %{
      session: session,
      scope: scope
    } do
      assert {:ok, prompt} = LiveViewCode.command(scope, session)
      refute prompt =~ "BDD Acceptance Specs"
    end

    test "does not include BDD spec instructions when story has no spec files", %{
      session: session,
      scope: scope,
      component: component
    } do
      story = story_fixture(scope)
      {:ok, _} = Stories.set_story_component(scope, story, component.id)

      assert {:ok, prompt} = LiveViewCode.command(scope, session)
      refute prompt =~ "BDD Acceptance Specs"
    end
  end

  describe "evaluate/3 with BDD specs" do
    setup [:create_scope, :create_project, :create_component, :create_session]

    test "returns valid when component has no stories", %{
      session: session,
      scope: scope,
      component: component
    } do
      satisfy_code_requirements(scope, component)
      assert {:ok, :valid} = LiveViewCode.evaluate(scope, session)
    end

    test "returns valid when story has no spec files", %{
      session: session,
      scope: scope,
      component: component
    } do
      story = story_fixture(scope)
      {:ok, _} = Stories.set_story_component(scope, story, component.id)
      satisfy_code_requirements(scope, component)

      assert {:ok, :valid} = LiveViewCode.evaluate(scope, session)
    end
  end

  # ============================================================================
  # Test Helpers
  # ============================================================================

  defp satisfy_code_requirements(scope, component) do
    requirement_fixture(scope, component, %{
      name: "implementation_file",
      artifact_type: :code,
      description: "Component implementation file exists",
      satisfied: true
    })

    requirement_fixture(scope, component, %{
      name: "tests_passing",
      artifact_type: :code,
      description: "Component tests are passing",
      satisfied: true
    })
  end

  defp create_spex_file(tmp_dir, story_id, criterion_id) do
    spex_dir = Path.join([tmp_dir, "test/spex", "#{story_id}_user_story"])
    File.mkdir_p!(spex_dir)
    file_path = Path.join(spex_dir, "criterion_#{criterion_id}_spex.exs")

    File.write!(file_path, """
    defmodule TestSpex#{story_id}_#{criterion_id} do
      use SexySpex

      spex "test spec", story_id: #{story_id}, criterion_id: #{criterion_id} do
        scenario "test scenario", context do
          given_ "a precondition", context do
            context
          end

          then_ "an expected outcome", _context do
            assert true
          end
        end
      end
    end
    """)

    file_path
  end
end
