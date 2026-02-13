defmodule CodeMySpec.AgentTasks.DevelopLiveViewTest do
  use CodeMySpec.DataCase, async: true

  alias CodeMySpec.AgentTasks.DevelopLiveView
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

  defp create_session(scope, liveview_component) do
    %{
      component: liveview_component,
      project: scope.active_project,
      external_conversation_id: "test-session-#{System.unique_integer([:positive])}"
    }
  end

  defp create_liveview_with_children(scope) do
    liveview =
      component_fixture(scope, %{
        name: "DashboardLive",
        type: "liveview",
        module_name: "TestAppWeb.DashboardLive"
      })

    child1 =
      component_fixture(scope, %{
        name: "StatsCard",
        type: "liveview_component",
        module_name: "TestAppWeb.DashboardLive.StatsCard",
        parent_component_id: liveview.id
      })

    child2 =
      component_fixture(scope, %{
        name: "ActivityFeed",
        type: "liveview_component",
        module_name: "TestAppWeb.DashboardLive.ActivityFeed",
        parent_component_id: liveview.id
      })

    {liveview, [child1, child2]}
  end

  defp create_spec_file!(tmp_dir, component, project) do
    spec_path = CodeMySpec.Utils.component_files(component, project).spec_file
    full_path = Path.join(tmp_dir, spec_path)
    full_path |> Path.dirname() |> File.mkdir_p!()

    content = valid_spec_content(component)
    File.write!(full_path, content)
    full_path
  end

  defp valid_spec_content(%{type: "liveview"} = component) do
    """
    # #{component.module_name}

    ## Route

    `/dashboard`

    ## Params

    None

    ## Child Components

    - StatsCard
    - ActivityFeed

    ## User Interactions

    - `refresh` → Reload dashboard data

    ## Dependencies

    - TestApp.Dashboard

    ## Design

    Layout: Full-width dashboard with card grid
    Components: .card, .stats, .btn-primary
    Responsive: Stack cards vertically on mobile
    """
  end

  defp valid_spec_content(%{type: "liveview_component"} = component) do
    """
    # #{component.module_name}

    ## Props

    - `data` - Map of component data

    ## Slots

    None

    ## Dependencies

    None
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

  defp create_design_review_file!(tmp_dir, component, project) do
    spec_path = CodeMySpec.Utils.component_files(component, project).spec_file
    review_path = String.replace_suffix(spec_path, ".spec.md", "/design_review.md")
    full_path = Path.join(tmp_dir, review_path)
    full_path |> Path.dirname() |> File.mkdir_p!()

    content = """
    # Design Review: #{component.name}

    ## Overview

    LiveView overview.

    ## Architecture

    Architecture details.

    ## Integration

    Integration notes.

    ## Conclusion

    APPROVED
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

  # Derive the status directory path the same way the implementation will
  defp liveview_status_dir(module_name) do
    parts =
      module_name
      |> String.split(".")
      |> Enum.map(&Macro.underscore/1)

    {dir_parts, [dirname]} = Enum.split(parts, -1)
    Path.join(["docs/status" | dir_parts] ++ [dirname])
  end

  defp read_orchestration_file(tmp_dir, module_name) do
    Path.join(tmp_dir, "#{liveview_status_dir(module_name)}/develop_live_view.md")
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
      {liveview, children} = create_liveview_with_children(scope)

      # Create all spec files
      create_spec_file!(tmp_dir, liveview, scope.active_project)

      for child <- children do
        create_spec_file!(tmp_dir, child, scope.active_project)
      end

      # Create design review
      create_design_review_file!(tmp_dir, liveview, scope.active_project)

      # Mark all requirements as satisfied
      for component <- [liveview | children] do
        create_satisfied_requirements!(scope, component, :specification)
        create_satisfied_requirements!(scope, component, :tests)
        create_satisfied_requirements!(scope, component, :code)
      end

      # Also mark review requirements as satisfied for the LiveView
      create_satisfied_requirements!(scope, liveview, :review)

      # Reload liveview with requirements
      liveview = Components.get_component(scope, liveview.id)
      session = create_session(scope, liveview)

      assert {:ok, _message} = DevelopLiveView.command(scope, session)
      content = read_orchestration_file(tmp_dir, liveview.module_name)
      assert content =~ "lifecycle is complete" or content =~ "complete"
      assert content =~ "No further action required"
    end

    test "generates LiveView spec prompt when LiveView spec is missing", %{tmp_dir: tmp_dir} do
      scope = create_scope_with_env(tmp_dir)
      {liveview, _children} = create_liveview_with_children(scope)
      session = create_session(scope, liveview)

      assert {:ok, _message} = DevelopLiveView.command(scope, session)
      content = read_orchestration_file(tmp_dir, liveview.module_name)
      assert content =~ "LiveView" or content =~ "Spec"

      # Verify prompt file was created in status directory
      status_dir = liveview_status_dir(liveview.module_name)
      safe_name = safe_filename(liveview.module_name)
      prompt_path = Path.join(tmp_dir, "#{status_dir}/#{safe_name}_live_view_spec.md")
      assert File.exists?(prompt_path)
    end

    test "generates component spec prompts for each child with missing spec", %{
      tmp_dir: tmp_dir
    } do
      scope = create_scope_with_env(tmp_dir)
      {liveview, children} = create_liveview_with_children(scope)

      # Create LiveView spec but not child specs
      create_spec_file!(tmp_dir, liveview, scope.active_project)

      # Mark LiveView spec requirements as satisfied
      create_satisfied_requirements!(scope, liveview, :specification)

      session = create_session(scope, liveview)

      assert {:ok, _message} = DevelopLiveView.command(scope, session)
      content = read_orchestration_file(tmp_dir, liveview.module_name)

      assert content =~ "Component" or content =~ "Spec"

      status_dir = liveview_status_dir(liveview.module_name)

      for child <- children do
        safe_name = safe_filename(child.module_name)
        prompt_path = Path.join(tmp_dir, "#{status_dir}/#{safe_name}_component_spec.md")
        assert File.exists?(prompt_path), "Expected prompt file for #{child.name}"
      end
    end

    test "generates design review prompt only when LiveView and component specs are complete", %{
      tmp_dir: tmp_dir
    } do
      scope = create_scope_with_env(tmp_dir)
      {liveview, children} = create_liveview_with_children(scope)

      # Create all spec files but not design review
      create_spec_file!(tmp_dir, liveview, scope.active_project)

      for child <- children do
        create_spec_file!(tmp_dir, child, scope.active_project)
      end

      # Mark spec requirements as satisfied so spec phase is complete
      for component <- [liveview | children] do
        create_satisfied_requirements!(scope, component, :specification)
      end

      session = create_session(scope, liveview)

      assert {:ok, _message} = DevelopLiveView.command(scope, session)
      content = read_orchestration_file(tmp_dir, liveview.module_name)
      assert content =~ "Design Review"

      status_dir = liveview_status_dir(liveview.module_name)
      safe_name = safe_filename(liveview.module_name)
      prompt_path = Path.join(tmp_dir, "#{status_dir}/#{safe_name}_design_review.md")
      assert File.exists?(prompt_path)
    end

    test "generates LiveViewTest prompt for parent when implementation phase and tests needed", %{
      tmp_dir: tmp_dir
    } do
      scope = create_scope_with_env(tmp_dir)
      {liveview, children} = create_liveview_with_children(scope)

      # Complete spec + design review phases
      create_spec_file!(tmp_dir, liveview, scope.active_project)

      for child <- children do
        create_spec_file!(tmp_dir, child, scope.active_project)
      end

      create_design_review_file!(tmp_dir, liveview, scope.active_project)
      create_satisfied_requirements!(scope, liveview, :review)

      # Mark spec requirements as satisfied
      for component <- [liveview | children] do
        create_satisfied_requirements!(scope, component, :specification)
      end

      # Mark parent LiveView as needing tests
      requirement_fixture(scope, liveview, %{
        name: "tests_requirement",
        artifact_type: :tests,
        satisfied: false
      })

      # Mark children as fully satisfied
      for child <- children do
        create_satisfied_requirements!(scope, child, :tests)
        create_satisfied_requirements!(scope, child, :code)
      end

      liveview = Components.get_component(scope, liveview.id)
      session = create_session(scope, liveview)

      assert {:ok, _message} = DevelopLiveView.command(scope, session)
      content = read_orchestration_file(tmp_dir, liveview.module_name)
      assert content =~ "Implementation"

      status_dir = liveview_status_dir(liveview.module_name)
      safe_name = safe_filename(liveview.module_name)
      test_path = Path.join(tmp_dir, "#{status_dir}/#{safe_name}_test.md")
      assert File.exists?(test_path), "Expected LiveViewTest prompt for parent"
    end

    test "generates LiveViewCode prompt for parent when implementation phase and code needed", %{
      tmp_dir: tmp_dir
    } do
      scope = create_scope_with_env(tmp_dir)
      {liveview, children} = create_liveview_with_children(scope)

      # Complete spec + design review phases
      create_spec_file!(tmp_dir, liveview, scope.active_project)

      for child <- children do
        create_spec_file!(tmp_dir, child, scope.active_project)
      end

      create_design_review_file!(tmp_dir, liveview, scope.active_project)
      create_satisfied_requirements!(scope, liveview, :review)

      # Mark spec requirements as satisfied
      for component <- [liveview | children] do
        create_satisfied_requirements!(scope, component, :specification)
      end

      # Mark parent LiveView as needing code (tests satisfied)
      create_satisfied_requirements!(scope, liveview, :tests)

      requirement_fixture(scope, liveview, %{
        name: "code_requirement",
        artifact_type: :code,
        satisfied: false
      })

      # Mark children as fully satisfied
      for child <- children do
        create_satisfied_requirements!(scope, child, :tests)
        create_satisfied_requirements!(scope, child, :code)
      end

      liveview = Components.get_component(scope, liveview.id)
      session = create_session(scope, liveview)

      assert {:ok, _message} = DevelopLiveView.command(scope, session)
      content = read_orchestration_file(tmp_dir, liveview.module_name)
      assert content =~ "Implementation"

      status_dir = liveview_status_dir(liveview.module_name)
      safe_name = safe_filename(liveview.module_name)
      code_path = Path.join(tmp_dir, "#{status_dir}/#{safe_name}_code.md")
      assert File.exists?(code_path), "Expected LiveViewCode prompt for parent"
    end

    test "generates ComponentTest prompts for children when implementation phase and tests needed",
         %{tmp_dir: tmp_dir} do
      scope = create_scope_with_env(tmp_dir)
      {liveview, children} = create_liveview_with_children(scope)

      # Complete spec + design review phases
      create_spec_file!(tmp_dir, liveview, scope.active_project)

      for child <- children do
        create_spec_file!(tmp_dir, child, scope.active_project)
      end

      create_design_review_file!(tmp_dir, liveview, scope.active_project)
      create_satisfied_requirements!(scope, liveview, :review)

      # Mark spec requirements as satisfied
      for component <- [liveview | children] do
        create_satisfied_requirements!(scope, component, :specification)
      end

      # Mark all as needing tests
      for component <- [liveview | children] do
        requirement_fixture(scope, component, %{
          name: "tests_requirement",
          artifact_type: :tests,
          satisfied: false
        })

        requirement_fixture(scope, component, %{
          name: "code_requirement",
          artifact_type: :code,
          satisfied: false
        })
      end

      liveview = Components.get_component(scope, liveview.id)
      session = create_session(scope, liveview)

      assert {:ok, _message} = DevelopLiveView.command(scope, session)

      status_dir = liveview_status_dir(liveview.module_name)

      for child <- children do
        safe_name = safe_filename(child.module_name)
        test_path = Path.join(tmp_dir, "#{status_dir}/#{safe_name}_test.md")
        assert File.exists?(test_path), "Expected ComponentTest prompt for #{child.name}"
      end
    end

    test "generates ComponentCode prompts for children when implementation phase and code needed",
         %{tmp_dir: tmp_dir} do
      scope = create_scope_with_env(tmp_dir)
      {liveview, children} = create_liveview_with_children(scope)

      # Complete spec + design review phases
      create_spec_file!(tmp_dir, liveview, scope.active_project)

      for child <- children do
        create_spec_file!(tmp_dir, child, scope.active_project)
      end

      create_design_review_file!(tmp_dir, liveview, scope.active_project)
      create_satisfied_requirements!(scope, liveview, :review)

      # Mark spec requirements as satisfied
      for component <- [liveview | children] do
        create_satisfied_requirements!(scope, component, :specification)
      end

      # Mark all as needing code
      for component <- [liveview | children] do
        create_satisfied_requirements!(scope, component, :tests)

        requirement_fixture(scope, component, %{
          name: "code_requirement",
          artifact_type: :code,
          satisfied: false
        })
      end

      liveview = Components.get_component(scope, liveview.id)
      session = create_session(scope, liveview)

      assert {:ok, _message} = DevelopLiveView.command(scope, session)

      status_dir = liveview_status_dir(liveview.module_name)

      for child <- children do
        safe_name = safe_filename(child.module_name)
        code_path = Path.join(tmp_dir, "#{status_dir}/#{safe_name}_code.md")
        assert File.exists?(code_path), "Expected ComponentCode prompt for #{child.name}"
      end
    end

    test "does not generate implementation prompts when design review is incomplete", %{
      tmp_dir: tmp_dir
    } do
      scope = create_scope_with_env(tmp_dir)
      {liveview, children} = create_liveview_with_children(scope)

      # Create all spec files but NO design review
      create_spec_file!(tmp_dir, liveview, scope.active_project)

      for child <- children do
        create_spec_file!(tmp_dir, child, scope.active_project)
      end

      # Mark spec requirements as satisfied
      for component <- [liveview | children] do
        create_satisfied_requirements!(scope, component, :specification)
      end

      # Create unsatisfied implementation requirements
      for component <- [liveview | children] do
        requirement_fixture(scope, component, %{
          name: "tests_requirement",
          artifact_type: :tests,
          satisfied: false
        })
      end

      liveview = Components.get_component(scope, liveview.id)
      session = create_session(scope, liveview)

      assert {:ok, _message} = DevelopLiveView.command(scope, session)
      content = read_orchestration_file(tmp_dir, liveview.module_name)

      # Should be in design review phase, not implementation
      assert content =~ "Design Review"

      # No implementation prompt files should exist
      status_dir = liveview_status_dir(liveview.module_name)

      for component <- [liveview | children] do
        safe_name = safe_filename(component.module_name)
        test_path = Path.join(tmp_dir, "#{status_dir}/#{safe_name}_test.md")
        code_path = Path.join(tmp_dir, "#{status_dir}/#{safe_name}_code.md")

        refute File.exists?(test_path),
               "Should not generate test prompt for #{component.name} before design review"

        refute File.exists?(code_path),
               "Should not generate code prompt for #{component.name} before design review"
      end
    end

    test "skips prompt generation for phases already complete", %{tmp_dir: tmp_dir} do
      scope = create_scope_with_env(tmp_dir)
      {liveview, children} = create_liveview_with_children(scope)

      # Complete LiveView spec phase
      create_spec_file!(tmp_dir, liveview, scope.active_project)

      # Complete child specs phase
      for child <- children do
        create_spec_file!(tmp_dir, child, scope.active_project)
      end

      # Mark spec requirements as satisfied
      for component <- [liveview | children] do
        create_satisfied_requirements!(scope, component, :specification)
      end

      session = create_session(scope, liveview)

      assert {:ok, _message} = DevelopLiveView.command(scope, session)

      status_dir = liveview_status_dir(liveview.module_name)

      # LiveView spec prompt should NOT be generated since phase is complete
      safe_name = safe_filename(liveview.module_name)
      spec_prompt_path = Path.join(tmp_dir, "#{status_dir}/#{safe_name}_live_view_spec.md")
      refute File.exists?(spec_prompt_path), "Should not generate spec prompt for completed phase"

      # Component spec prompts should NOT be generated since phase is complete
      for child <- children do
        child_safe_name = safe_filename(child.module_name)
        child_prompt_path = Path.join(tmp_dir, "#{status_dir}/#{child_safe_name}_component_spec.md")

        refute File.exists?(child_prompt_path),
               "Should not generate component spec prompt for #{child.name}"
      end
    end

    test "writes prompt files to correct status directory structure", %{tmp_dir: tmp_dir} do
      scope = create_scope_with_env(tmp_dir)
      {liveview, _children} = create_liveview_with_children(scope)
      session = create_session(scope, liveview)

      assert {:ok, _prompt} = DevelopLiveView.command(scope, session)

      # Verify directory structure under docs/status/
      expected_dir = Path.join(tmp_dir, liveview_status_dir(liveview.module_name))
      assert File.exists?(expected_dir)
      assert File.dir?(expected_dir)
    end

    test "returns orchestration prompt with current phase and prompt file list", %{
      tmp_dir: tmp_dir
    } do
      scope = create_scope_with_env(tmp_dir)
      {liveview, _children} = create_liveview_with_children(scope)
      session = create_session(scope, liveview)

      assert {:ok, _message} = DevelopLiveView.command(scope, session)
      content = read_orchestration_file(tmp_dir, liveview.module_name)

      assert content =~ "LiveView Lifecycle" or content =~ "Lifecycle"
      assert content =~ "Lifecycle Phases" or content =~ "Phases"
      assert content =~ "Current Phase"
      assert content =~ "Subagent" or content =~ "subagent"
      assert content =~ "spec-writer"
      assert content =~ "Prompt files" or content =~ "prompt"
      assert content =~ "docs/status/"
    end

    test "includes dependency order guidance for implementation phase (children first, parent last)",
         %{tmp_dir: tmp_dir} do
      scope = create_scope_with_env(tmp_dir)
      {liveview, children} = create_liveview_with_children(scope)

      # Complete spec + design review phases
      create_spec_file!(tmp_dir, liveview, scope.active_project)

      for child <- children do
        create_spec_file!(tmp_dir, child, scope.active_project)
      end

      create_design_review_file!(tmp_dir, liveview, scope.active_project)
      create_satisfied_requirements!(scope, liveview, :review)

      # Mark spec requirements as satisfied
      for component <- [liveview | children] do
        create_satisfied_requirements!(scope, component, :specification)
      end

      # Create unsatisfied implementation requirements
      for component <- [liveview | children] do
        requirement_fixture(scope, component, %{
          name: "tests_requirement",
          artifact_type: :tests,
          satisfied: false
        })

        requirement_fixture(scope, component, %{
          name: "code_requirement",
          artifact_type: :code,
          satisfied: false
        })
      end

      liveview = Components.get_component(scope, liveview.id)
      session = create_session(scope, liveview)

      assert {:ok, _message} = DevelopLiveView.command(scope, session)
      content = read_orchestration_file(tmp_dir, liveview.module_name)

      # Should mention dependency order with children before parent
      assert content =~ "child" or content =~ "Children"
      assert content =~ "parent" or content =~ "LiveView"
      assert content =~ "dependency order" or content =~ "order"
    end
  end

  # ============================================================================
  # evaluate/3 Tests
  # ============================================================================

  describe "evaluate/3" do
    test "returns {:ok, :valid} when all phases are complete", %{tmp_dir: tmp_dir} do
      scope = create_scope_with_env(tmp_dir)
      {liveview, children} = create_liveview_with_children(scope)

      create_spec_file!(tmp_dir, liveview, scope.active_project)

      for child <- children do
        create_spec_file!(tmp_dir, child, scope.active_project)
      end

      create_design_review_file!(tmp_dir, liveview, scope.active_project)

      for component <- [liveview | children] do
        create_satisfied_requirements!(scope, component, :specification)
        create_satisfied_requirements!(scope, component, :tests)
        create_satisfied_requirements!(scope, component, :code)
      end

      create_satisfied_requirements!(scope, liveview, :review)

      liveview = Components.get_component(scope, liveview.id)
      session = create_session(scope, liveview)

      assert {:ok, :valid} = DevelopLiveView.evaluate(scope, session)
    end

    test "returns {:ok, :invalid, feedback} when LiveView spec phase is incomplete", %{
      tmp_dir: tmp_dir
    } do
      scope = create_scope_with_env(tmp_dir)
      {liveview, _children} = create_liveview_with_children(scope)
      session = create_session(scope, liveview)

      assert {:ok, :invalid, feedback} = DevelopLiveView.evaluate(scope, session)
      assert is_binary(feedback)
      assert feedback =~ "LiveView" or feedback =~ "Spec"
    end

    test "returns {:ok, :invalid, feedback} when component specs phase is incomplete", %{
      tmp_dir: tmp_dir
    } do
      scope = create_scope_with_env(tmp_dir)
      {liveview, _children} = create_liveview_with_children(scope)

      # Complete LiveView spec phase
      create_spec_file!(tmp_dir, liveview, scope.active_project)
      create_satisfied_requirements!(scope, liveview, :specification)

      session = create_session(scope, liveview)

      assert {:ok, :invalid, feedback} = DevelopLiveView.evaluate(scope, session)
      assert is_binary(feedback)
      assert feedback =~ "Component" or feedback =~ "Spec" or feedback =~ "incomplete"
    end

    test "returns {:ok, :invalid, feedback} when design review phase is incomplete", %{
      tmp_dir: tmp_dir
    } do
      scope = create_scope_with_env(tmp_dir)
      {liveview, children} = create_liveview_with_children(scope)

      # Complete spec phases
      create_spec_file!(tmp_dir, liveview, scope.active_project)

      for child <- children do
        create_spec_file!(tmp_dir, child, scope.active_project)
      end

      # Mark spec requirements as satisfied
      for component <- [liveview | children] do
        create_satisfied_requirements!(scope, component, :specification)
      end

      session = create_session(scope, liveview)

      assert {:ok, :invalid, feedback} = DevelopLiveView.evaluate(scope, session)
      assert is_binary(feedback)
      assert feedback =~ "Design Review" or feedback =~ "review" or feedback =~ "incomplete"
    end

    test "returns {:ok, :invalid, feedback} when implementation phase is incomplete", %{
      tmp_dir: tmp_dir
    } do
      scope = create_scope_with_env(tmp_dir)
      {liveview, children} = create_liveview_with_children(scope)

      # Complete spec + design review phases
      create_spec_file!(tmp_dir, liveview, scope.active_project)

      for child <- children do
        create_spec_file!(tmp_dir, child, scope.active_project)
      end

      create_design_review_file!(tmp_dir, liveview, scope.active_project)
      create_satisfied_requirements!(scope, liveview, :review)

      # Mark spec requirements as satisfied
      for component <- [liveview | children] do
        create_satisfied_requirements!(scope, component, :specification)
      end

      # Create unsatisfied implementation requirements
      for component <- [liveview | children] do
        requirement_fixture(scope, component, %{
          name: "tests_requirement",
          artifact_type: :tests,
          satisfied: false
        })
      end

      liveview = Components.get_component(scope, liveview.id)
      session = create_session(scope, liveview)

      assert {:ok, :invalid, feedback} = DevelopLiveView.evaluate(scope, session)
      assert is_binary(feedback)
      assert feedback =~ "Implementation" or feedback =~ "implementation" or feedback =~ "incomplete"
    end

    test "feedback includes list of incomplete phases and affected components", %{
      tmp_dir: tmp_dir
    } do
      scope = create_scope_with_env(tmp_dir)
      {liveview, _children} = create_liveview_with_children(scope)
      session = create_session(scope, liveview)

      assert {:ok, :invalid, feedback} = DevelopLiveView.evaluate(scope, session)
      assert feedback =~ "incomplete phases" or feedback =~ "incomplete"
      assert feedback =~ liveview.name
    end

    test "feedback includes status directory path and subagent instructions", %{
      tmp_dir: tmp_dir
    } do
      scope = create_scope_with_env(tmp_dir)
      {liveview, _children} = create_liveview_with_children(scope)
      session = create_session(scope, liveview)

      assert {:ok, :invalid, feedback} = DevelopLiveView.evaluate(scope, session)
      assert feedback =~ liveview.module_name
      assert feedback =~ liveview_status_dir(liveview.module_name)
    end

    test "cleans up prompt files for completed phases", %{tmp_dir: tmp_dir} do
      scope = create_scope_with_env(tmp_dir)
      {liveview, children} = create_liveview_with_children(scope)

      # Create all spec files to mark spec phases complete
      create_spec_file!(tmp_dir, liveview, scope.active_project)

      for child <- children do
        create_spec_file!(tmp_dir, child, scope.active_project)
      end

      # Mark spec requirements as satisfied
      for component <- [liveview | children] do
        create_satisfied_requirements!(scope, component, :specification)
      end

      session = create_session(scope, liveview)

      # Command should generate design review prompt
      assert {:ok, _message} = DevelopLiveView.command(scope, session)
      content = read_orchestration_file(tmp_dir, liveview.module_name)
      assert content =~ "Design Review"

      status_dir = liveview_status_dir(liveview.module_name)
      safe_name = safe_filename(liveview.module_name)
      design_review_prompt = Path.join(tmp_dir, "#{status_dir}/#{safe_name}_design_review.md")
      assert File.exists?(design_review_prompt)

      # Now create the design review file to complete that phase
      create_design_review_file!(tmp_dir, liveview, scope.active_project)
      create_satisfied_requirements!(scope, liveview, :review)

      # Reload liveview
      liveview = Components.get_component(scope, liveview.id)
      session = create_session(scope, liveview)

      # Evaluate should clean up completed phase prompt files
      result = DevelopLiveView.evaluate(scope, session)

      case result do
        {:ok, :valid} -> assert true
        {:ok, :invalid, _feedback} -> assert true
        other -> flunk("Unexpected result: #{inspect(other)}")
      end

      # Design review prompt should be cleaned up since design_review phase is now complete
      refute File.exists?(design_review_prompt),
             "Design review prompt should be cleaned up after phase completes"
    end

    test "removes status directory when all phases complete", %{tmp_dir: tmp_dir} do
      scope = create_scope_with_env(tmp_dir)
      {liveview, children} = create_liveview_with_children(scope)

      # Create all spec files
      create_spec_file!(tmp_dir, liveview, scope.active_project)

      for child <- children do
        create_spec_file!(tmp_dir, child, scope.active_project)
      end

      # Create design review
      create_design_review_file!(tmp_dir, liveview, scope.active_project)

      # Mark all requirements as satisfied
      for component <- [liveview | children] do
        create_satisfied_requirements!(scope, component, :specification)
        create_satisfied_requirements!(scope, component, :tests)
        create_satisfied_requirements!(scope, component, :code)
      end

      create_satisfied_requirements!(scope, liveview, :review)

      # Create status directory with a leftover file
      status_dir_path = Path.join(tmp_dir, liveview_status_dir(liveview.module_name))
      File.mkdir_p!(status_dir_path)
      File.write!(Path.join(status_dir_path, "develop_live_view.md"), "old content")

      # Reload liveview with requirements
      liveview = Components.get_component(scope, liveview.id)
      session = create_session(scope, liveview)

      assert {:ok, :valid} = DevelopLiveView.evaluate(scope, session)

      # Status directory should be removed when all phases complete
      refute File.exists?(status_dir_path),
             "Status directory should be removed when all phases complete"
    end

    test "regenerates prompt files for current incomplete phase on invalid", %{tmp_dir: tmp_dir} do
      scope = create_scope_with_env(tmp_dir)
      {liveview, children} = create_liveview_with_children(scope)

      # Complete phases 1-3: specs + design review
      create_spec_file!(tmp_dir, liveview, scope.active_project)

      for child <- children do
        create_spec_file!(tmp_dir, child, scope.active_project)
      end

      create_design_review_file!(tmp_dir, liveview, scope.active_project)
      create_satisfied_requirements!(scope, liveview, :review)

      # Mark spec requirements as satisfied
      for component <- [liveview | children] do
        create_satisfied_requirements!(scope, component, :specification)
      end

      # Create unsatisfied test requirements (implementation phase needed)
      for component <- [liveview | children] do
        requirement_fixture(scope, component, %{
          name: "tests_requirement",
          artifact_type: :tests,
          satisfied: false
        })
      end

      liveview = Components.get_component(scope, liveview.id)
      session = create_session(scope, liveview)

      # Initial command generates implementation prompts
      assert {:ok, _message} = DevelopLiveView.command(scope, session)

      # Now call evaluate - it should regenerate prompts for the implementation phase
      assert {:ok, :invalid, feedback} = DevelopLiveView.evaluate(scope, session)

      # Verify test prompt files are generated
      status_dir = liveview_status_dir(liveview.module_name)
      safe_name = safe_filename(liveview.module_name)
      test_prompt_path = Path.join(tmp_dir, "#{status_dir}/#{safe_name}_test.md")

      assert File.exists?(test_prompt_path),
             "Test prompt file should be generated for implementation phase"

      # Verify orchestration file is updated to show implementation as current phase
      orchestration_content = read_orchestration_file(tmp_dir, liveview.module_name)
      assert orchestration_content =~ "Implementation"

      # Verify old design review prompt files are cleaned up
      design_review_prompt = Path.join(tmp_dir, "#{status_dir}/#{safe_name}_design_review.md")

      refute File.exists?(design_review_prompt),
             "Design review prompt should be cleaned up after phase completes"

      # Verify feedback references status directory
      assert feedback =~ "develop_live_view.md"
      assert feedback =~ "incomplete phases" or feedback =~ "incomplete"
    end
  end
end
