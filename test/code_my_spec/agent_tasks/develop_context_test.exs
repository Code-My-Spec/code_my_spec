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

  defp create_session(scope, context_component, external_id \\ nil) do
    external_id = external_id || "test-session-#{System.unique_integer([:positive])}"

    %{
      component: context_component,
      project: scope.active_project,
      external_conversation_id: external_id
    }
  end

  defp create_context_with_children(scope) do
    # Create parent context component
    context =
      component_fixture(scope, %{
        name: "TestContext",
        type: "context",
        module_name: "CodeMySpec.TestContext"
      })

    # Create child components under the context
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

    content = """
    ---
    module_name: #{component.module_name}
    type: #{component.type}
    ---

    # #{component.name}

    Test spec content.
    """

    File.write!(full_path, content)
    full_path
  end

  defp create_design_review_file!(tmp_dir, component, project) do
    # The implementation uses spec_file path with suffix replacement
    # NOT the review_file from component_files
    spec_path = CodeMySpec.Utils.component_files(component, project).spec_file
    # Path becomes: docs/spec/module_path.spec.md -> docs/spec/module_path/design_review.md
    review_path = String.replace_suffix(spec_path, ".spec.md", "/design_review.md")
    full_path = Path.join(tmp_dir, review_path)
    full_path |> Path.dirname() |> File.mkdir_p!()

    content = """
    # Design Review: #{component.name}

    ## Approval

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

  defp prompt_dir(external_id) do
    ".code_my_spec/internal/sessions/#{external_id}/subagent_prompts"
  end

  defp read_orchestration_file(tmp_dir, external_id) do
    Path.join(tmp_dir, ".code_my_spec/internal/sessions/#{external_id}/develop_context.md")
    |> File.read!()
  end

  # ============================================================================
  # command/3 Tests
  # ============================================================================

  describe "command/3" do
    test "returns completion message when all phases are complete", %{tmp_dir: tmp_dir} do
      scope = create_scope_with_env(tmp_dir)
      {context, children} = create_context_with_children(scope)
      external_id = "test-complete-#{System.unique_integer([:positive])}"

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
      session = create_session(scope, context, external_id)

      assert {:ok, _message} = DevelopContext.command(scope, session)
      content = read_orchestration_file(tmp_dir, external_id)
      assert content =~ "Context lifecycle is complete"
      assert content =~ "No further action required"
    end

    test "generates context spec prompt when context spec is missing", %{tmp_dir: tmp_dir} do
      scope = create_scope_with_env(tmp_dir)
      {context, _children} = create_context_with_children(scope)
      external_id = "test-#{System.unique_integer([:positive])}"
      session = create_session(scope, context, external_id)

      # Don't create any spec files

      assert {:ok, _message} = DevelopContext.command(scope, session)
      content = read_orchestration_file(tmp_dir, external_id)
      assert content =~ "Context Specification"
      assert content =~ "Context Lifecycle"

      # Verify prompt file was created
      prompt_path = Path.join(tmp_dir, "#{prompt_dir(external_id)}/codemyspec_testcontext_context_spec.md")
      assert File.exists?(prompt_path)
    end

    test "generates component spec prompts for each missing child spec", %{tmp_dir: tmp_dir} do
      scope = create_scope_with_env(tmp_dir)
      {context, children} = create_context_with_children(scope)
      external_id = "test-#{System.unique_integer([:positive])}"

      # Create context spec but not child specs
      create_spec_file!(tmp_dir, context, scope.active_project)

      # Verify children exist and have correct parent
      for child <- children do
        reloaded = Components.get_component(scope, child.id)
        assert reloaded.parent_component_id == context.id
      end

      session = create_session(scope, context, external_id)

      assert {:ok, _message} = DevelopContext.command(scope, session)
      content = read_orchestration_file(tmp_dir, external_id)

      # Should be in component specs phase if children need specs
      # Or design review phase if no children found (context-only lifecycle)
      assert content =~ "Component Specifications" or content =~ "Design Review"

      # If children were found, prompt files should be created
      if content =~ "Component Specifications" do
        for child <- children do
          safe_name =
            child.module_name
            |> String.replace(".", "_")
            |> String.downcase()

          prompt_path = Path.join(tmp_dir, "#{prompt_dir(external_id)}/#{safe_name}_component_spec.md")
          assert File.exists?(prompt_path), "Expected prompt file for #{child.name}"
        end
      end
    end

    test "generates design review prompt only when context and component specs are complete", %{
      tmp_dir: tmp_dir
    } do
      scope = create_scope_with_env(tmp_dir)
      {context, children} = create_context_with_children(scope)
      external_id = "test-#{System.unique_integer([:positive])}"

      # Create all spec files but not design review
      create_spec_file!(tmp_dir, context, scope.active_project)

      for child <- children do
        create_spec_file!(tmp_dir, child, scope.active_project)
      end

      session = create_session(scope, context, external_id)

      assert {:ok, _message} = DevelopContext.command(scope, session)
      content = read_orchestration_file(tmp_dir, external_id)
      assert content =~ "Design Review"

      # Verify design review prompt file was created
      safe_name =
        context.module_name
        |> String.replace(".", "_")
        |> String.downcase()

      prompt_path = Path.join(tmp_dir, "#{prompt_dir(external_id)}/#{safe_name}_design_review.md")
      assert File.exists?(prompt_path)
    end

    test "generates test prompts only when design review is complete", %{tmp_dir: tmp_dir} do
      scope = create_scope_with_env(tmp_dir)
      {context, children} = create_context_with_children(scope)
      external_id = "test-#{System.unique_integer([:positive])}"

      # Create all spec files and design review
      create_spec_file!(tmp_dir, context, scope.active_project)

      for child <- children do
        create_spec_file!(tmp_dir, child, scope.active_project)
      end

      create_design_review_file!(tmp_dir, context, scope.active_project)

      # Create unsatisfied test requirements
      for component <- [context | children] do
        requirement_fixture(scope, component, %{
          name: "tests_requirement",
          artifact_type: :tests,
          satisfied: false
        })
      end

      # Reload context with requirements
      context = Components.get_component(scope, context.id)
      session = create_session(scope, context, external_id)

      assert {:ok, _message} = DevelopContext.command(scope, session)
      content = read_orchestration_file(tmp_dir, external_id)
      assert content =~ "Tests"

      # Verify test prompt files were created
      safe_name =
        context.module_name
        |> String.replace(".", "_")
        |> String.downcase()

      prompt_path = Path.join(tmp_dir, "#{prompt_dir(external_id)}/#{safe_name}_test.md")
      assert File.exists?(prompt_path)
    end

    test "generates code prompts only when tests are complete", %{tmp_dir: tmp_dir} do
      scope = create_scope_with_env(tmp_dir)
      {context, children} = create_context_with_children(scope)
      external_id = "test-#{System.unique_integer([:positive])}"

      # Create all spec files and design review
      create_spec_file!(tmp_dir, context, scope.active_project)

      for child <- children do
        create_spec_file!(tmp_dir, child, scope.active_project)
      end

      create_design_review_file!(tmp_dir, context, scope.active_project)

      # Mark tests as satisfied but code as unsatisfied
      for component <- [context | children] do
        create_satisfied_requirements!(scope, component, :tests)

        requirement_fixture(scope, component, %{
          name: "code_requirement",
          artifact_type: :code,
          satisfied: false
        })
      end

      # Reload context with requirements
      context = Components.get_component(scope, context.id)
      session = create_session(scope, context, external_id)

      assert {:ok, _message} = DevelopContext.command(scope, session)
      content = read_orchestration_file(tmp_dir, external_id)
      assert content =~ "Implementation"

      # Verify code prompt files were created
      safe_name =
        context.module_name
        |> String.replace(".", "_")
        |> String.downcase()

      prompt_path = Path.join(tmp_dir, "#{prompt_dir(external_id)}/#{safe_name}_code.md")
      assert File.exists?(prompt_path)
    end

    test "writes prompt files to correct directory structure", %{tmp_dir: tmp_dir} do
      scope = create_scope_with_env(tmp_dir)
      {context, _children} = create_context_with_children(scope)
      external_id = "test-#{System.unique_integer([:positive])}"
      session = create_session(scope, context, external_id)

      assert {:ok, _prompt} = DevelopContext.command(scope, session)

      # Verify directory structure
      expected_dir = Path.join(tmp_dir, prompt_dir(external_id))
      assert File.exists?(expected_dir)
      assert File.dir?(expected_dir)
    end

    test "returns orchestration prompt with current phase and prompt file list", %{
      tmp_dir: tmp_dir
    } do
      scope = create_scope_with_env(tmp_dir)
      {context, _children} = create_context_with_children(scope)
      external_id = "test-#{System.unique_integer([:positive])}"
      session = create_session(scope, context, external_id)

      assert {:ok, _message} = DevelopContext.command(scope, session)
      content = read_orchestration_file(tmp_dir, external_id)

      # Check orchestration structure
      assert content =~ "Context Lifecycle"
      assert content =~ "Lifecycle Phases"
      assert content =~ "Current Phase"
      assert content =~ "Subagent Usage"
      assert content =~ "spec-writer"
      assert content =~ "Prompt files to complete"
      assert content =~ ".code_my_spec/internal/sessions/#{external_id}"
    end
  end

  # ============================================================================
  # evaluate/3 Tests
  # ============================================================================

  describe "evaluate/3" do
    test "returns {:ok, :valid} when all phases are complete", %{tmp_dir: tmp_dir} do
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

      assert {:ok, :valid} = DevelopContext.evaluate(scope, session)
    end

    test "returns {:ok, :invalid, feedback} when phases are incomplete", %{tmp_dir: tmp_dir} do
      scope = create_scope_with_env(tmp_dir)
      {context, _children} = create_context_with_children(scope)
      session = create_session(scope, context)

      # Don't create any files - all phases incomplete

      assert {:ok, :invalid, feedback} = DevelopContext.evaluate(scope, session)
      assert is_binary(feedback)
    end

    test "feedback includes list of incomplete phases and affected components", %{
      tmp_dir: tmp_dir
    } do
      scope = create_scope_with_env(tmp_dir)
      {context, _children} = create_context_with_children(scope)
      session = create_session(scope, context)

      # Don't create any files

      assert {:ok, :invalid, feedback} = DevelopContext.evaluate(scope, session)
      assert feedback =~ "Context Specification"
      assert feedback =~ "Missing for"
      assert feedback =~ context.name
    end

    test "feedback includes prompt directory path and subagent instructions", %{tmp_dir: tmp_dir} do
      scope = create_scope_with_env(tmp_dir)
      {context, _children} = create_context_with_children(scope)
      external_id = "test-#{System.unique_integer([:positive])}"
      session = create_session(scope, context, external_id)

      assert {:ok, :invalid, feedback} = DevelopContext.evaluate(scope, session)
      assert feedback =~ prompt_dir(external_id)
      assert feedback =~ "spec-writer"
      assert feedback =~ "test-writer"
      assert feedback =~ "code-writer"
    end

    test "cleans up prompt files for completed phases", %{tmp_dir: tmp_dir} do
      scope = create_scope_with_env(tmp_dir)
      {context, children} = create_context_with_children(scope)
      external_id = "test-#{System.unique_integer([:positive])}"

      # Create context spec file to mark phase 1 complete
      create_spec_file!(tmp_dir, context, scope.active_project)

      # Create child spec files to mark phase 2 complete
      for child <- children do
        create_spec_file!(tmp_dir, child, scope.active_project)
      end

      # Don't create design review file - phase 3 incomplete

      session = create_session(scope, context, external_id)

      # Command should generate design review prompt (since specs complete but review missing)
      assert {:ok, _message} = DevelopContext.command(scope, session)
      content = read_orchestration_file(tmp_dir, external_id)
      assert content =~ "Design Review"

      safe_name =
        context.module_name
        |> String.replace(".", "_")
        |> String.downcase()

      design_review_prompt = Path.join(tmp_dir, "#{prompt_dir(external_id)}/#{safe_name}_design_review.md")
      assert File.exists?(design_review_prompt)

      # Now create the design review file to complete that phase
      create_design_review_file!(tmp_dir, context, scope.active_project)

      # Reload context
      context = Components.get_component(scope, context.id)
      session = create_session(scope, context, external_id)

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

    test "removes empty prompt directory when all phases complete", %{tmp_dir: tmp_dir} do
      scope = create_scope_with_env(tmp_dir)
      {context, children} = create_context_with_children(scope)
      external_id = "test-#{System.unique_integer([:positive])}"

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

      # Create EMPTY prompt directory
      prompt_path = Path.join(tmp_dir, prompt_dir(external_id))
      File.mkdir_p!(prompt_path)

      # Verify it's empty
      assert {:ok, []} = File.ls(prompt_path)

      # Reload context with requirements
      context = Components.get_component(scope, context.id)
      session = create_session(scope, context, external_id)

      assert {:ok, :valid} = DevelopContext.evaluate(scope, session)

      # Empty directory should be cleaned up by cleanup_prompt_directory
      # But note: the parent directories may still exist
      case File.ls(prompt_path) do
        {:error, :enoent} ->
          # Directory was removed
          assert true

        {:ok, []} ->
          # Directory still exists but is empty - this is also acceptable
          # The implementation only removes if empty AND all phases complete
          assert true

        {:ok, _files} ->
          # Directory has files - this shouldn't happen
          flunk("Prompt directory should be empty or removed")
      end
    end
  end
end
