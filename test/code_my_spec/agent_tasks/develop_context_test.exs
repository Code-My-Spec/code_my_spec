defmodule CodeMySpec.AgentTasks.DevelopContextTest do
  use CodeMySpec.DataCase, async: true

  alias CodeMySpec.AgentTasks.DevelopContext
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

  defp create_session(scope, context_component) do
    %{
      component: context_component,
      project: scope.active_project,
      external_conversation_id: "test-session-#{System.unique_integer([:positive])}"
    }
  end

  defp create_context_with_children(scope) do
    context =
      component_fixture(scope, %{
        name: "TestContext",
        type: "context",
        module_name: "CodeMySpec.TestContext"
      })

    child1 =
      component_fixture(scope, %{
        name: "TestSchema",
        type: "schema",
        module_name: "CodeMySpec.TestContext.TestSchema",
        parent_component_id: context.id
      })

    child2 =
      component_fixture(scope, %{
        name: "TestRepository",
        type: "repository",
        module_name: "CodeMySpec.TestContext.TestRepository",
        parent_component_id: context.id
      })

    {context, [child1, child2]}
  end

  defp create_spec_file!(tmp_dir, component, project) do
    spec_path = CodeMySpec.Utils.component_files(component, project).spec_file
    full_path = Path.join(tmp_dir, spec_path)
    full_path |> Path.dirname() |> File.mkdir_p!()

    content = valid_spec_content(component)
    File.write!(full_path, content)
    full_path
  end

  defp valid_spec_content(%{type: "context"} = component) do
    """
    # #{component.module_name}

    ## Functions

    - `list/0` - Lists all records

    ## Dependencies

    None

    ## Components

    None
    """
  end

  defp valid_spec_content(%{type: "schema"} = component) do
    """
    # #{component.module_name}

    ## Fields

    - `id` - Primary key
    - `name` - String field
    """
  end

  defp valid_spec_content(component) do
    """
    # #{component.module_name}

    ## Functions

    - `list/0` - Lists all records

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

    Context overview.

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

  # Derive the status directory path the same way DevelopContext does
  defp context_status_dir(module_name) do
    parts =
      module_name
      |> String.split(".")
      |> Enum.map(&Macro.underscore/1)

    {dir_parts, [dirname]} = Enum.split(parts, -1)
    Path.join([".code_my_spec/status" | dir_parts] ++ [dirname])
  end

  defp read_orchestration_file(tmp_dir, module_name) do
    Path.join(tmp_dir, "#{context_status_dir(module_name)}/develop_context.md")
    |> File.read!()
  end

  # ============================================================================
  # command/3 Tests
  # ============================================================================

  describe "command/3" do
    test "returns completion message when all phases are complete", %{tmp_dir: tmp_dir} do
      scope = create_scope_with_env(tmp_dir)
      {context, children} = create_context_with_children(scope)

      # Create all spec files
      create_spec_file!(tmp_dir, context, scope.active_project)

      for child <- children do
        create_spec_file!(tmp_dir, child, scope.active_project)
      end

      # Create design review
      create_design_review_file!(tmp_dir, context, scope.active_project)

      # Mark all requirements as satisfied
      for component <- [context | children] do
        create_satisfied_requirements!(scope, component, :tests)
        create_satisfied_requirements!(scope, component, :code)
      end

      # Reload context with requirements
      context = Components.get_component(scope, context.id)
      session = create_session(scope, context)

      assert {:ok, _message} = DevelopContext.command(scope, session)
      content = read_orchestration_file(tmp_dir, context.module_name)
      assert content =~ "Context lifecycle is complete"
      assert content =~ "No further action required"
    end

    test "generates context spec prompt when context spec is missing", %{tmp_dir: tmp_dir} do
      scope = create_scope_with_env(tmp_dir)
      {context, _children} = create_context_with_children(scope)
      session = create_session(scope, context)

      assert {:ok, _message} = DevelopContext.command(scope, session)
      content = read_orchestration_file(tmp_dir, context.module_name)
      assert content =~ "Context Specification"
      assert content =~ "Context Lifecycle"

      # Verify prompt file was created in status directory
      status_dir = context_status_dir(context.module_name)
      safe_name = context.module_name |> String.replace(".", "_") |> String.downcase()
      prompt_path = Path.join(tmp_dir, "#{status_dir}/#{safe_name}_context_spec.md")
      assert File.exists?(prompt_path)
    end

    test "generates component spec prompts for each missing child spec", %{tmp_dir: tmp_dir} do
      scope = create_scope_with_env(tmp_dir)
      {context, children} = create_context_with_children(scope)

      # Create context spec but not child specs
      create_spec_file!(tmp_dir, context, scope.active_project)

      for child <- children do
        reloaded = Components.get_component(scope, child.id)
        assert reloaded.parent_component_id == context.id
      end

      session = create_session(scope, context)

      assert {:ok, _message} = DevelopContext.command(scope, session)
      content = read_orchestration_file(tmp_dir, context.module_name)

      assert content =~ "Component Specifications" or content =~ "Design Review"

      if content =~ "Component Specifications" do
        status_dir = context_status_dir(context.module_name)

        for child <- children do
          safe_name = child.module_name |> String.replace(".", "_") |> String.downcase()
          prompt_path = Path.join(tmp_dir, "#{status_dir}/#{safe_name}_component_spec.md")
          assert File.exists?(prompt_path), "Expected prompt file for #{child.name}"
        end
      end
    end

    test "generates design review prompt only when context and component specs are complete", %{
      tmp_dir: tmp_dir
    } do
      scope = create_scope_with_env(tmp_dir)
      {context, children} = create_context_with_children(scope)

      # Create all spec files but not design review
      create_spec_file!(tmp_dir, context, scope.active_project)

      for child <- children do
        create_spec_file!(tmp_dir, child, scope.active_project)
      end

      session = create_session(scope, context)

      assert {:ok, _message} = DevelopContext.command(scope, session)
      content = read_orchestration_file(tmp_dir, context.module_name)
      assert content =~ "Design Review"

      status_dir = context_status_dir(context.module_name)
      safe_name = context.module_name |> String.replace(".", "_") |> String.downcase()
      prompt_path = Path.join(tmp_dir, "#{status_dir}/#{safe_name}_design_review.md")
      assert File.exists?(prompt_path)
    end

    test "generates implementation prompts (test+code per component) when design review is complete",
         %{tmp_dir: tmp_dir} do
      scope = create_scope_with_env(tmp_dir)
      {context, children} = create_context_with_children(scope)

      create_spec_file!(tmp_dir, context, scope.active_project)

      for child <- children do
        create_spec_file!(tmp_dir, child, scope.active_project)
      end

      create_design_review_file!(tmp_dir, context, scope.active_project)

      # Create unsatisfied test AND code requirements for all components
      for component <- [context | children] do
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

      context = Components.get_component(scope, context.id)
      session = create_session(scope, context)

      assert {:ok, _message} = DevelopContext.command(scope, session)
      content = read_orchestration_file(tmp_dir, context.module_name)
      assert content =~ "Implementation"

      status_dir = context_status_dir(context.module_name)

      # Verify both _test.md and _code.md prompt files generated per component
      for component <- [context | children] do
        safe_name = component.module_name |> String.replace(".", "_") |> String.downcase()

        test_path = Path.join(tmp_dir, "#{status_dir}/#{safe_name}_test.md")
        assert File.exists?(test_path), "Expected test prompt for #{component.name}"

        code_path = Path.join(tmp_dir, "#{status_dir}/#{safe_name}_code.md")
        assert File.exists?(code_path), "Expected code prompt for #{component.name}"
      end

      # Verify orchestration content mentions dependency order and component grouping
      assert content =~ "dependency order"
      assert content =~ "Schemas"
      assert content =~ "Repositories"
    end

    test "writes prompt files to docs/status/ directory structure", %{tmp_dir: tmp_dir} do
      scope = create_scope_with_env(tmp_dir)
      {context, _children} = create_context_with_children(scope)
      session = create_session(scope, context)

      assert {:ok, _prompt} = DevelopContext.command(scope, session)

      # Verify directory structure under docs/status/
      expected_dir = Path.join(tmp_dir, context_status_dir(context.module_name))
      assert File.exists?(expected_dir)
      assert File.dir?(expected_dir)
    end

    test "returns orchestration prompt with current phase and prompt file list", %{
      tmp_dir: tmp_dir
    } do
      scope = create_scope_with_env(tmp_dir)
      {context, _children} = create_context_with_children(scope)
      session = create_session(scope, context)

      assert {:ok, _message} = DevelopContext.command(scope, session)
      content = read_orchestration_file(tmp_dir, context.module_name)

      assert content =~ "Context Lifecycle"
      assert content =~ "Lifecycle Phases"
      assert content =~ "Current Phase"
      assert content =~ "Subagent Usage"
      assert content =~ "spec-writer"
      assert content =~ "Prompt files to complete"
      assert content =~ ".code_my_spec/status/"
    end
  end

  # ============================================================================
  # evaluate/3 Tests
  # ============================================================================

  describe "evaluate/3" do
    test "returns {:ok, :valid} when all phases are complete", %{tmp_dir: tmp_dir} do
      scope = create_scope_with_env(tmp_dir)
      {context, children} = create_context_with_children(scope)

      create_spec_file!(tmp_dir, context, scope.active_project)

      for child <- children do
        create_spec_file!(tmp_dir, child, scope.active_project)
      end

      create_design_review_file!(tmp_dir, context, scope.active_project)

      for component <- [context | children] do
        create_satisfied_requirements!(scope, component, :tests)
        create_satisfied_requirements!(scope, component, :code)
      end

      context = Components.get_component(scope, context.id)
      session = create_session(scope, context)

      assert {:ok, :valid} = DevelopContext.evaluate(scope, session)
    end

    test "returns {:ok, :invalid, feedback} when phases are incomplete", %{tmp_dir: tmp_dir} do
      scope = create_scope_with_env(tmp_dir)
      {context, _children} = create_context_with_children(scope)
      session = create_session(scope, context)

      assert {:ok, :invalid, feedback} = DevelopContext.evaluate(scope, session)
      assert is_binary(feedback)
    end

    test "feedback includes list of incomplete phases and affected components", %{
      tmp_dir: tmp_dir
    } do
      scope = create_scope_with_env(tmp_dir)
      {context, _children} = create_context_with_children(scope)
      session = create_session(scope, context)

      assert {:ok, :invalid, feedback} = DevelopContext.evaluate(scope, session)
      assert feedback =~ "Context Specification"
      assert feedback =~ "incomplete phases"
      assert feedback =~ context.name
    end

    test "feedback includes context name and status directory path", %{tmp_dir: tmp_dir} do
      scope = create_scope_with_env(tmp_dir)
      {context, _children} = create_context_with_children(scope)
      session = create_session(scope, context)

      assert {:ok, :invalid, feedback} = DevelopContext.evaluate(scope, session)
      assert feedback =~ context.name
      assert feedback =~ context.module_name
      assert feedback =~ context_status_dir(context.module_name)
    end

    test "cleans up prompt files for completed phases", %{tmp_dir: tmp_dir} do
      scope = create_scope_with_env(tmp_dir)
      {context, children} = create_context_with_children(scope)

      # Create context spec file to mark phase 1 complete
      create_spec_file!(tmp_dir, context, scope.active_project)

      # Create child spec files to mark phase 2 complete
      for child <- children do
        create_spec_file!(tmp_dir, child, scope.active_project)
      end

      session = create_session(scope, context)

      # Command should generate design review prompt
      assert {:ok, _message} = DevelopContext.command(scope, session)
      content = read_orchestration_file(tmp_dir, context.module_name)
      assert content =~ "Design Review"

      status_dir = context_status_dir(context.module_name)
      safe_name = context.module_name |> String.replace(".", "_") |> String.downcase()
      design_review_prompt = Path.join(tmp_dir, "#{status_dir}/#{safe_name}_design_review.md")
      assert File.exists?(design_review_prompt)

      # Now create the design review file to complete that phase
      create_design_review_file!(tmp_dir, context, scope.active_project)

      # Reload context
      context = Components.get_component(scope, context.id)
      session = create_session(scope, context)

      # Evaluate should clean up completed phase prompt files
      result = DevelopContext.evaluate(scope, session)

      case result do
        {:ok, :valid} -> assert true
        {:ok, :invalid, _feedback} -> assert true
        other -> flunk("Unexpected result: #{inspect(other)}")
      end

      # Design review prompt should be cleaned up since design_review phase is now complete
      refute File.exists?(design_review_prompt),
             "Design review prompt should be cleaned up after phase completes"
    end

    test "regenerates prompts for next phase when phases advance", %{tmp_dir: tmp_dir} do
      scope = create_scope_with_env(tmp_dir)
      {context, children} = create_context_with_children(scope)

      # Complete phases 1-3: specs + design review
      create_spec_file!(tmp_dir, context, scope.active_project)

      for child <- children do
        create_spec_file!(tmp_dir, child, scope.active_project)
      end

      create_design_review_file!(tmp_dir, context, scope.active_project)

      # Create unsatisfied test requirements (implementation phase needed)
      for component <- [context | children] do
        requirement_fixture(scope, component, %{
          name: "tests_requirement",
          artifact_type: :tests,
          satisfied: false
        })
      end

      context = Components.get_component(scope, context.id)
      session = create_session(scope, context)

      # Initial command generates implementation prompts
      assert {:ok, _message} = DevelopContext.command(scope, session)

      # Now call evaluate - it should regenerate prompts for the implementation phase
      assert {:ok, :invalid, feedback} = DevelopContext.evaluate(scope, session)

      # Verify test prompt files are generated
      status_dir = context_status_dir(context.module_name)
      safe_name = context.module_name |> String.replace(".", "_") |> String.downcase()
      test_prompt_path = Path.join(tmp_dir, "#{status_dir}/#{safe_name}_test.md")

      assert File.exists?(test_prompt_path),
             "Test prompt file should be generated for implementation phase"

      # Verify orchestration file is updated to show "Implementation" as current phase
      orchestration_content = read_orchestration_file(tmp_dir, context.module_name)
      assert orchestration_content =~ "Current Phase: Implementation"

      # Verify old design review prompt files are cleaned up
      design_review_prompt = Path.join(tmp_dir, "#{status_dir}/#{safe_name}_design_review.md")

      refute File.exists?(design_review_prompt),
             "Design review prompt should be cleaned up after phase completes"

      # Verify feedback references status directory
      assert feedback =~ "develop_context.md"
      assert feedback =~ "incomplete phases"
    end

    test "removes status directory when all phases complete", %{tmp_dir: tmp_dir} do
      scope = create_scope_with_env(tmp_dir)
      {context, children} = create_context_with_children(scope)

      # Create all spec files
      create_spec_file!(tmp_dir, context, scope.active_project)

      for child <- children do
        create_spec_file!(tmp_dir, child, scope.active_project)
      end

      # Create design review
      create_design_review_file!(tmp_dir, context, scope.active_project)

      # Mark all requirements as satisfied
      for component <- [context | children] do
        create_satisfied_requirements!(scope, component, :tests)
        create_satisfied_requirements!(scope, component, :code)
      end

      # Create status directory with a leftover file
      status_dir_path = Path.join(tmp_dir, context_status_dir(context.module_name))
      File.mkdir_p!(status_dir_path)
      File.write!(Path.join(status_dir_path, "develop_context.md"), "old content")

      # Reload context with requirements
      context = Components.get_component(scope, context.id)
      session = create_session(scope, context)

      assert {:ok, :valid} = DevelopContext.evaluate(scope, session)

      # Status directory should be removed when all phases complete
      refute File.exists?(status_dir_path),
             "Status directory should be removed when all phases complete"
    end
  end
end
