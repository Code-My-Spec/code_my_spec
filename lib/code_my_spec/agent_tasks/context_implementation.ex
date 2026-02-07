defmodule CodeMySpec.AgentTasks.ContextImplementation do
  @moduledoc """
  Orchestrates implementing an entire context (tests + code for the context and all child components) via subagents.

  Two main functions:
  - `command/3` - Generates prompt files for test-writer and code-writer subagents, returns orchestration prompt
  - `evaluate/3` - Validates all components (including context itself) pass test and code quality checks
  """

  alias CodeMySpec.{Requirements, Environments}
  alias CodeMySpec.Components.ComponentRepository
  alias CodeMySpec.AgentTasks.{ComponentTest, ComponentCode}

  defp prompt_dir(external_id),
    do: ".code_my_spec/internal/sessions/#{external_id}/subagent_prompts"

  @doc """
  Generate prompt files and orchestration instructions for implementing a context and its child components.

  Checks both the context itself and all children for unsatisfied test/code requirements.

  Returns {:ok, prompt_text}
  """
  def command(scope, session, _opts \\ []) do
    %{component: context_component, external_conversation_id: external_id} = session
    # Ensure requirements are preloaded on context component
    context_component = ComponentRepository.get_component(scope, context_component.id)

    with {:ok, children} <- get_child_components(scope, context_component),
         # Include context itself in the list of components to check
         all_components = [context_component | children],
         {:ok, components_needing_tests} <-
           filter_components_needing_tests(scope, all_components, session),
         {:ok, components_needing_code} <-
           filter_components_needing_code(scope, all_components, session),
         {:ok, prompt_files} <-
           generate_prompt_files(
             scope,
             session,
             components_needing_tests,
             components_needing_code,
             external_id
           ) do
      build_orchestration_prompt(context_component, prompt_files, external_id)
    end
  end

  @doc """
  Validate the context and all child components have passing tests and implementations.

  Returns:
  - {:ok, :valid} if context and all children pass both test and code evaluations
  - {:ok, :invalid, feedback} if some components have failing checks
  - {:error, reason} if evaluation failed
  """
  def evaluate(scope, session, opts \\ []) do
    %{component: context_component, external_conversation_id: external_id} = session
    # Ensure requirements are preloaded on context component
    context_component = ComponentRepository.get_component(scope, context_component.id)

    with {:ok, children} <- get_child_components(scope, context_component),
         # Include context itself in the list of components to evaluate
         all_components = [context_component | children],
         {:ok, test_results} <- evaluate_tests(scope, session, all_components, opts),
         {:ok, code_results} <- evaluate_code(scope, session, all_components, opts),
         {:ok, satisfied, unsatisfied} <-
           aggregate_results(all_components, test_results, code_results),
         :ok <- cleanup_prompt_files(satisfied, external_id) do
      case unsatisfied do
        [] ->
          cleanup_prompt_directory(external_id)
          {:ok, :valid}

        failed_components ->
          feedback = build_feedback(failed_components, external_id)
          {:ok, :invalid, feedback}
      end
    end
  end

  # Private functions

  defp get_child_components(scope, context_component) do
    # Use recursive descent to get all children, grandchildren, etc.
    # This handles nested structures like subdirectories
    children = ComponentRepository.list_all_descendants(scope, context_component.id)
    {:ok, children}
  end

  defp filter_components_needing_tests(scope, children, _session) do
    needing_tests =
      Enum.filter(children, fn child ->
        # Filter persisted requirements to test-related ones
        results =
          Requirements.check_requirements(
            scope,
            child,
            child.requirements,
            artifact_types: [:tests]
          )

        Enum.any?(results, fn result -> not result.satisfied end)
      end)

    {:ok, needing_tests}
  end

  defp filter_components_needing_code(scope, children, _session) do
    needing_code =
      Enum.filter(children, fn child ->
        # Filter persisted requirements to code-related ones
        results =
          Requirements.check_requirements(
            scope,
            child,
            child.requirements,
            artifact_types: [:code]
          )

        Enum.any?(results, fn result -> not result.satisfied end)
      end)

    {:ok, needing_code}
  end

  defp generate_prompt_files(
         scope,
         session,
         components_needing_tests,
         components_needing_code,
         external_id
       ) do
    %{project: project} = session
    environment = scope.environment

    # Generate test prompt files
    test_prompts =
      Enum.map(components_needing_tests, fn child ->
        child_session = %{
          component: child,
          project: project
        }

        {:ok, prompt_content} = ComponentTest.command(scope, child_session)

        safe_name = safe_filename(child.module_name)
        file_path = "#{prompt_dir(external_id)}/#{safe_name}_test.md"
        :ok = Environments.write_file(environment, file_path, prompt_content)

        %{
          component: child,
          file_path: file_path,
          prompt_type: :test
        }
      end)

    # Generate code prompt files
    code_prompts =
      Enum.map(components_needing_code, fn child ->
        child_session = %{
          component: child,
          project: project
        }

        {:ok, prompt_content} = ComponentCode.command(scope, child_session)

        safe_name = safe_filename(child.module_name)
        file_path = "#{prompt_dir(external_id)}/#{safe_name}_code.md"
        :ok = Environments.write_file(environment, file_path, prompt_content)

        %{
          component: child,
          file_path: file_path,
          prompt_type: :code
        }
      end)

    {:ok, test_prompts ++ code_prompts}
  end

  defp safe_filename(module_name) do
    module_name
    |> String.replace(".", "_")
    |> String.downcase()
  end

  defp build_orchestration_prompt(context_component, [], _external_id) do
    {:ok,
     """
     Context #{context_component.name} and all its child components already have passing tests and implementations.
     No further action required.
     """}
  end

  defp build_orchestration_prompt(context_component, prompt_files, _external_id) do
    # Group by component to show test + code together
    by_component =
      prompt_files
      |> Enum.group_by(& &1.component.id)
      |> Enum.map(fn {_id, files} ->
        component = hd(files).component
        test_file = Enum.find(files, &(&1.prompt_type == :test))
        code_file = Enum.find(files, &(&1.prompt_type == :code))
        {component, test_file, code_file}
      end)
      |> Enum.sort_by(fn {comp, _, _} -> comp.name end)

    component_tasks =
      Enum.map_join(by_component, "\n", fn {component, test_file, code_file} ->
        test_section =
          if test_file do
            "   - Test prompt: #{test_file.file_path}"
          else
            "   - Tests: already passing"
          end

        code_section =
          if code_file do
            "   - Code prompt: #{code_file.file_path}"
          else
            "   - Code: already passing"
          end

        """
        ### #{component.name} (#{component.type})
        #{test_section}
        #{code_section}
        """
      end)

    total_components = length(by_component)

    {:ok,
     """
     # Context Implementation: #{context_component.name}

     You are the **integrator** for this context. Your job is to orchestrate subagents
     to implement child components, then write the context module itself as the public API.

     ## Your Role as Integrator

     1. **Delegate implementation work** to test-writer and code-writer subagents
     2. **Write the context module** (#{context_component.module_name}) as the public API:
        - Use `defdelegate` to expose child component functions
        - Write thin coordination logic between components
        - The context should be mostly delegation, not business logic
     3. **Handle API mismatches**: If a child component's API doesn't integrate cleanly:
        - Update that component's specification to fix the API
        - Invoke `@"CodeMySpec:code-writer (agent)"` to implement the spec change
        - Components should be designed to compose cleanly - minimal glue code

     ## Implementation Order

     Implement in dependency order:
     - **Schemas** first (no dependencies)
     - **Repositories** next (depend on schemas)
     - **Services/Logic** (depend on repositories and schemas)
     - **Context module** last (delegates to and coordinates all the above)

     For each layer: write tests first, then implement.

     ## Implementation Flow

     For each component (in dependency order):
     1. Invoke `@"CodeMySpec:test-writer (agent)"` with the test prompt file
     2. Wait for tests to be written
     3. Invoke `@"CodeMySpec:code-writer (agent)"` with the code prompt file
     4. Verify tests pass before moving to next layer

     You can parallelize within a layer (e.g., multiple schemas at once).

     ## Components to Implement

     #{total_components} component(s):

     #{component_tasks}

     ## Writing the Context Module

     When you implement the context itself:
     - Read the context's specification for the public API contract
     - Use `defdelegate` for simple pass-through functions
     - Only write coordination logic when multiple components must work together
     - If integration requires awkward glue code, that's a signal to fix the child component's API

     ## Completion

     The stop hook will validate all components have:
     - Tests that compile and align with specs
     - Implementations that pass all tests
     """}
  end

  defp evaluate_tests(scope, session, children, opts) do
    results =
      Enum.map(children, fn child ->
        child_session = %{
          component: child,
          project: session.project
        }

        result = ComponentTest.evaluate(scope, child_session, opts)
        {child, :test, result}
      end)

    {:ok, results}
  end

  defp evaluate_code(scope, session, children, opts) do
    results =
      Enum.map(children, fn child ->
        child_session = %{
          component: child,
          project: session.project
        }

        result = ComponentCode.evaluate(scope, child_session, opts)
        {child, :code, result}
      end)

    {:ok, results}
  end

  defp aggregate_results(children, test_results, code_results) do
    # Build a map of component_id -> {test_result, code_result}
    test_map = Map.new(test_results, fn {child, :test, result} -> {child.id, result} end)
    code_map = Map.new(code_results, fn {child, :code, result} -> {child.id, result} end)

    {satisfied, unsatisfied} =
      Enum.split_with(children, fn child ->
        test_ok = match?({:ok, :valid}, test_map[child.id])
        code_ok = match?({:ok, :valid}, code_map[child.id])
        test_ok and code_ok
      end)

    unsatisfied_with_details =
      Enum.map(unsatisfied, fn child ->
        test_result = test_map[child.id]
        code_result = code_map[child.id]

        errors = []

        errors =
          case test_result do
            {:ok, :invalid, feedback} -> errors ++ [{:test, feedback}]
            {:error, reason} -> errors ++ [{:test, "Error: #{inspect(reason)}"}]
            _ -> errors
          end

        errors =
          case code_result do
            {:ok, :invalid, feedback} -> errors ++ [{:code, feedback}]
            {:error, reason} -> errors ++ [{:code, "Error: #{inspect(reason)}"}]
            _ -> errors
          end

        %{component: child, errors: errors}
      end)

    {:ok, satisfied, unsatisfied_with_details}
  end

  defp cleanup_prompt_files(satisfied_children, external_id) do
    Enum.each(satisfied_children, fn child ->
      safe_name = safe_filename(child.module_name)

      # Clean up both test and code prompt files
      Enum.each(["_test.md", "_code.md"], fn suffix ->
        file_path = "#{prompt_dir(external_id)}/#{safe_name}#{suffix}"

        if File.exists?(file_path) do
          File.rm(file_path)
        end
      end)
    end)

    :ok
  end

  defp cleanup_prompt_directory(external_id) do
    dir = prompt_dir(external_id)

    if File.exists?(dir) and File.dir?(dir) do
      case File.ls(dir) do
        {:ok, []} -> File.rmdir(dir)
        _ -> :ok
      end
    end

    :ok
  end

  defp build_feedback(unsatisfied_components, external_id) do
    components_list =
      Enum.map_join(unsatisfied_components, "\n\n", fn %{component: comp, errors: errors} ->
        error_text =
          Enum.map_join(errors, "\n    ", fn {type, feedback} ->
            "#{type}: #{feedback}"
          end)

        "- #{comp.name} (#{comp.module_name}):\n    #{error_text}"
      end)

    """
    The following components have failing tests or implementations:

    #{components_list}

    Please fix the issues and re-run the subagents:
    - For test failures: invoke `@"CodeMySpec:test-writer (agent)"` with the test prompt
    - For code failures: invoke `@"CodeMySpec:code-writer (agent)"` with the code prompt

    Prompt files are located in #{prompt_dir(external_id)}/
    """
  end
end
