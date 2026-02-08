defmodule CodeMySpec.AgentTasks.DevelopContext do
  @moduledoc """
  Orchestrates the full lifecycle of a context from specification through implementation.

  Creates prompt files for all subagent tasks in order:
  1. Context spec (ContextSpec)
  2. Component specs (ComponentSpec) for each child
  3. Design review (ContextDesignReview)
  4. Tests for each component (ComponentTest)
  5. Code for each component (ComponentCode)

  Two main functions:
  - `command/3` - Generates prompt files for all lifecycle phases, returns orchestration prompt
  - `evaluate/3` - Validates all phases complete and cleans up prompt files
  """

  require Logger

  alias CodeMySpec.Components.ComponentRepository
  alias CodeMySpec.Utils

  alias CodeMySpec.AgentTasks.{
    ComponentCode,
    ComponentSpec,
    ComponentTest,
    ContextDesignReview,
    ContextSpec
  }

  defp session_dir(external_id), do: ".code_my_spec/internal/sessions/#{external_id}"

  defp prompt_dir(external_id),
    do: "#{session_dir(external_id)}/subagent_prompts"

  # Helper to get external ID from session (supports both old map format and new struct format)
  defp get_external_id(session) do
    Map.get(session, :external_conversation_id) || Map.get(session, :external_id)
  end

  @doc """
  Generate prompt files and orchestration instructions for the full context lifecycle.

  Checks each phase (spec, design review, test, code) and generates prompt files
  for incomplete phases.

  Returns {:ok, prompt_text}
  """
  def command(scope, session, _opts \\ []) do
    %{component: context_component} = session
    external_id = get_external_id(session)
    # Ensure requirements and children are preloaded
    context_component = ComponentRepository.get_component(scope, context_component.id)

    with {:ok, children} <- get_child_components(scope, context_component),
         {:ok, phase_status} <- check_lifecycle_phases(scope, session, context_component, children),
         {:ok, prompt_files} <-
           generate_phase_prompts(scope, session, context_component, children, phase_status, external_id) do
      {:ok, orchestration_content} =
        build_orchestration_prompt(context_component, phase_status, prompt_files, external_id)

      orchestration_path = "#{session_dir(external_id)}/develop_context.md"
      CodeMySpec.Environments.write_file(scope.environment, orchestration_path, orchestration_content)

      {:ok, "Your instructions have been written to: `#{orchestration_path}`\n\nRead this file to begin."}
    end
  end

  @doc """
  Validate all lifecycle phases are complete for the context.

  Returns:
  - {:ok, :valid} if all phases pass
  - {:ok, :invalid, feedback} if some phases are incomplete
  - {:error, reason} if evaluation failed
  """
  def evaluate(scope, session, _opts \\ []) do
    %{component: context_component} = session
    external_id = get_external_id(session)
    # Ensure requirements and children are preloaded
    context_component = ComponentRepository.get_component(scope, context_component.id)

    working_dir = scope.environment && scope.environment.cwd

    with {:ok, children} <- get_child_components(scope, context_component),
         {:ok, phase_status} <- check_lifecycle_phases(scope, session, context_component, children),
         :ok <- cleanup_completed_phases(phase_status, external_id, working_dir) do
      case phase_status do
        %{complete: true} ->
          cleanup_prompt_directory(external_id, working_dir)
          {:ok, :valid}

        %{incomplete_phases: incomplete} ->
          feedback = build_feedback(incomplete, external_id)
          {:ok, :invalid, feedback}
      end
    end
  end

  # Private functions - Phase checking

  defp get_child_components(scope, context_component) do
    children = ComponentRepository.list_all_descendants(scope, context_component.id)
    {:ok, children}
  end

  defp check_lifecycle_phases(scope, session, context_component, children) do
    # Check each phase in order
    context_spec_status = check_context_spec(scope, session, context_component)
    component_specs_status = check_component_specs(scope, session, children)
    design_review_status = check_design_review(scope, session, context_component)
    tests_status = check_tests(scope, session, [context_component | children])
    code_status = check_code(scope, session, [context_component | children])

    incomplete_phases =
      []
      |> maybe_add_phase(:context_spec, context_spec_status)
      |> maybe_add_phase(:component_specs, component_specs_status)
      |> maybe_add_phase(:design_review, design_review_status)
      |> maybe_add_phase(:tests, tests_status)
      |> maybe_add_phase(:code, code_status)

    status =
      if Enum.empty?(incomplete_phases) do
        %{complete: true}
      else
        %{
          complete: false,
          incomplete_phases: incomplete_phases,
          context_spec: context_spec_status,
          component_specs: component_specs_status,
          design_review: design_review_status,
          tests: tests_status,
          code: code_status
        }
      end

    {:ok, status}
  end

  defp maybe_add_phase(phases, _name, :complete), do: phases
  defp maybe_add_phase(phases, name, status), do: [{name, status} | phases]

  defp check_context_spec(scope, session, context_component) do
    %{spec_file: spec_path} = Utils.component_files(context_component, session.project)

    environment = scope.environment

    if environment && CodeMySpec.Environments.file_exists?(environment, spec_path) do
      :complete
    else
      {:missing, [context_component]}
    end
  end

  defp check_component_specs(scope, session, children) do
    environment = scope.environment

    missing =
      Enum.filter(children, fn child ->
        %{spec_file: spec_path} = Utils.component_files(child, session.project)

        if environment do
          not CodeMySpec.Environments.file_exists?(environment, spec_path)
        else
          true
        end
      end)

    if Enum.empty?(missing) do
      :complete
    else
      {:missing, missing}
    end
  end

  defp check_design_review(scope, session, context_component) do
    %{spec_file: spec_path} = Utils.component_files(context_component, session.project)
    review_path = String.replace_suffix(spec_path, ".spec.md", "/design_review.md")

    environment = scope.environment

    if environment && CodeMySpec.Environments.file_exists?(environment, review_path) do
      :complete
    else
      {:missing, [context_component]}
    end
  end

  defp check_tests(scope, _session, components) do
    needing_tests =
      Enum.filter(components, fn component ->
        results =
          CodeMySpec.Requirements.check_requirements(
            scope,
            component,
            component.requirements || [],
            artifact_types: [:tests]
          )

        Enum.any?(results, fn result -> not result.satisfied end)
      end)

    if Enum.empty?(needing_tests) do
      :complete
    else
      {:missing, needing_tests}
    end
  end

  defp check_code(scope, _session, components) do
    needing_code =
      Enum.filter(components, fn component ->
        results =
          CodeMySpec.Requirements.check_requirements(
            scope,
            component,
            component.requirements || [],
            artifact_types: [:code]
          )

        Enum.any?(results, fn result -> not result.satisfied end)
      end)

    if Enum.empty?(needing_code) do
      :complete
    else
      {:missing, needing_code}
    end
  end

  # Private functions - Prompt generation

  defp generate_phase_prompts(scope, session, context_component, _children, phase_status, external_id) do
    environment = scope.environment

    ctx = %{
      scope: scope,
      session: session,
      context_component: context_component,
      environment: environment,
      external_id: external_id
    }

    prompt_files =
      []
      |> maybe_add_context_spec_prompts(phase_status, ctx)
      |> maybe_add_component_spec_prompts(phase_status, ctx)
      |> maybe_add_design_review_prompts(phase_status, ctx)
      |> maybe_add_test_prompts(phase_status, ctx)
      |> maybe_add_code_prompts(phase_status, ctx)

    {:ok, prompt_files}
  end

  defp maybe_add_context_spec_prompts(acc, %{context_spec: {:missing, _}} = _status, ctx) do
    acc ++ generate_context_spec_prompt(ctx.scope, ctx.session, ctx.context_component, ctx.environment, ctx.external_id)
  end

  defp maybe_add_context_spec_prompts(acc, _status, _ctx), do: acc

  defp maybe_add_component_spec_prompts(acc, %{component_specs: {:missing, missing}}, ctx) do
    acc ++ generate_component_spec_prompts(ctx.scope, ctx.session, missing, ctx.environment, ctx.external_id)
  end

  defp maybe_add_component_spec_prompts(acc, _status, _ctx), do: acc

  defp maybe_add_design_review_prompts(acc, %{context_spec: :complete, component_specs: :complete, design_review: {:missing, _}}, ctx) do
    acc ++ generate_design_review_prompt(ctx.scope, ctx.session, ctx.context_component, ctx.environment, ctx.external_id)
  end

  defp maybe_add_design_review_prompts(acc, _status, _ctx), do: acc

  defp maybe_add_test_prompts(acc, %{design_review: :complete, tests: {:missing, missing}}, ctx) do
    acc ++ generate_test_prompts(ctx.scope, ctx.session, missing, ctx.environment, ctx.external_id)
  end

  defp maybe_add_test_prompts(acc, _status, _ctx), do: acc

  defp maybe_add_code_prompts(acc, %{tests: :complete, code: {:missing, missing}}, ctx) do
    acc ++ generate_code_prompts(ctx.scope, ctx.session, missing, ctx.environment, ctx.external_id)
  end

  defp maybe_add_code_prompts(acc, _status, _ctx), do: acc

  defp generate_context_spec_prompt(scope, session, context_component, environment, external_id) do
    child_session = %{
      component: context_component,
      project: session.project
    }

    {:ok, prompt_content} = ContextSpec.command(scope, child_session)

    safe_name = safe_filename(context_component.module_name)
    file_path = "#{prompt_dir(external_id)}/#{safe_name}_context_spec.md"
    :ok = CodeMySpec.Environments.write_file(environment, file_path, prompt_content)

    [%{
      component: context_component,
      file_path: file_path,
      prompt_type: :context_spec,
      phase: 1
    }]
  end

  defp generate_component_spec_prompts(scope, session, children, environment, external_id) do
    Enum.map(children, fn child ->
      child_session = %{
        component: child,
        project: session.project
      }

      {:ok, prompt_content} = ComponentSpec.command(scope, child_session)

      safe_name = safe_filename(child.module_name)
      file_path = "#{prompt_dir(external_id)}/#{safe_name}_component_spec.md"
      :ok = CodeMySpec.Environments.write_file(environment, file_path, prompt_content)

      %{
        component: child,
        file_path: file_path,
        prompt_type: :component_spec,
        phase: 2
      }
    end)
  end

  defp generate_design_review_prompt(scope, session, context_component, environment, external_id) do
    child_session = %{
      component: context_component,
      project: session.project
    }

    {:ok, prompt_content} = ContextDesignReview.command(scope, child_session)

    safe_name = safe_filename(context_component.module_name)
    file_path = "#{prompt_dir(external_id)}/#{safe_name}_design_review.md"
    :ok = CodeMySpec.Environments.write_file(environment, file_path, prompt_content)

    [%{
      component: context_component,
      file_path: file_path,
      prompt_type: :design_review,
      phase: 3
    }]
  end

  defp generate_test_prompts(scope, session, components, environment, external_id) do
    Enum.map(components, fn component ->
      child_session = %{
        component: component,
        project: session.project
      }

      {:ok, prompt_content} = ComponentTest.command(scope, child_session)

      safe_name = safe_filename(component.module_name)
      file_path = "#{prompt_dir(external_id)}/#{safe_name}_test.md"
      :ok = CodeMySpec.Environments.write_file(environment, file_path, prompt_content)

      %{
        component: component,
        file_path: file_path,
        prompt_type: :test,
        phase: 4
      }
    end)
  end

  defp generate_code_prompts(scope, session, components, environment, external_id) do
    Enum.map(components, fn component ->
      child_session = %{
        component: component,
        project: session.project
      }

      {:ok, prompt_content} = ComponentCode.command(scope, child_session)

      safe_name = safe_filename(component.module_name)
      file_path = "#{prompt_dir(external_id)}/#{safe_name}_code.md"
      :ok = CodeMySpec.Environments.write_file(environment, file_path, prompt_content)

      %{
        component: component,
        file_path: file_path,
        prompt_type: :code,
        phase: 5
      }
    end)
  end

  defp safe_filename(module_name) do
    module_name
    |> String.replace(".", "_")
    |> String.downcase()
  end

  # Private functions - Prompt building

  defp build_orchestration_prompt(_context_component, %{complete: true}, _prompt_files, _external_id) do
    {:ok,
     """
     Context lifecycle is complete. All phases have passed:
     - Context specification
     - Component specifications
     - Design review
     - Tests
     - Implementation

     No further action required.
     """}
  end

  defp build_orchestration_prompt(context_component, phase_status, prompt_files, _external_id) do
    current_phase = determine_current_phase(phase_status)
    phase_text = format_phase_instructions(current_phase, prompt_files)

    {:ok,
     """
     # Context Lifecycle: #{context_component.name}

     You are orchestrating the full development lifecycle for this context.

     ## Lifecycle Phases

     1. **Context Spec** - Define the bounded context architecture
     2. **Component Specs** - Design each child component
     3. **Design Review** - Validate architecture before implementation
     4. **Tests** - Write tests for each component
     5. **Code** - Implement each component

     ## Current Phase: #{format_phase_name(current_phase)}

     #{phase_text}

     ## Subagent Usage

     Invoke the appropriate subagent for each prompt file:

     - For spec prompts: `@"CodeMySpec:spec-writer (agent)"`
     - For test prompts: `@"CodeMySpec:test-writer (agent)"`
     - For code prompts: `@"CodeMySpec:code-writer (agent)"`

     ## Workflow

     1. Complete all tasks in the current phase
     2. The stop hook will validate and advance to the next phase
     3. Continue until all phases complete

     ## Completion

     The stop hook will validate:
     - All spec files exist and are valid
     - Design review passes
     - All tests compile and align with specs
     - All implementations pass tests
     """}
  end

  defp determine_current_phase(phase_status) do
    cond do
      match?({:missing, _}, phase_status[:context_spec]) -> :context_spec
      match?({:missing, _}, phase_status[:component_specs]) -> :component_specs
      match?({:missing, _}, phase_status[:design_review]) -> :design_review
      match?({:missing, _}, phase_status[:tests]) -> :tests
      match?({:missing, _}, phase_status[:code]) -> :code
      true -> :complete
    end
  end

  defp format_phase_name(:context_spec), do: "Context Specification"
  defp format_phase_name(:component_specs), do: "Component Specifications"
  defp format_phase_name(:design_review), do: "Design Review"
  defp format_phase_name(:tests), do: "Tests"
  defp format_phase_name(:code), do: "Implementation"
  defp format_phase_name(:complete), do: "Complete"

  defp format_phase_instructions(phase, prompt_files) do
    phase_files = Enum.filter(prompt_files, fn pf -> pf.prompt_type == phase or pf.phase == phase_to_number(phase) end)

    if Enum.empty?(phase_files) do
      "No prompt files generated for this phase."
    else
      file_list =
        Enum.map_join(phase_files, "\n", fn pf ->
          "- [ ] #{pf.component.name}: `#{pf.file_path}`"
        end)

      """
      Prompt files to complete:

      #{file_list}

      Read each prompt file and invoke the appropriate subagent.
      """
    end
  end

  defp phase_to_number(:context_spec), do: 1
  defp phase_to_number(:component_specs), do: 2
  defp phase_to_number(:component_spec), do: 2
  defp phase_to_number(:design_review), do: 3
  defp phase_to_number(:tests), do: 4
  defp phase_to_number(:test), do: 4
  defp phase_to_number(:code), do: 5
  defp phase_to_number(_), do: 0

  # Private functions - Cleanup

  defp cleanup_completed_phases(phase_status, external_id, working_dir) do
    # When all phases complete, phase_status is %{complete: true} without individual keys
    # In that case, clean up ALL phase files
    completed_suffixes =
      if phase_status[:complete] == true do
        [:context_spec, :component_specs, :design_review, :tests, :code]
        |> Enum.flat_map(&phase_to_suffixes/1)
      else
        [:context_spec, :component_specs, :design_review, :tests, :code]
        |> Enum.filter(fn phase -> phase_status[phase] == :complete end)
        |> Enum.flat_map(&phase_to_suffixes/1)
      end

    dir = resolve_prompt_dir(external_id, working_dir)

    with true <- File.exists?(dir),
         {:ok, files} <- File.ls(dir) do
      files
      |> Enum.filter(&file_matches_suffixes?(&1, completed_suffixes))
      |> Enum.each(&File.rm(Path.join(dir, &1)))
    end

    :ok
  end

  defp file_matches_suffixes?(file, suffixes) do
    Enum.any?(suffixes, &String.ends_with?(file, &1))
  end

  defp phase_to_suffixes(:context_spec), do: ["_context_spec.md"]
  defp phase_to_suffixes(:component_specs), do: ["_component_spec.md"]
  defp phase_to_suffixes(:design_review), do: ["_design_review.md"]
  defp phase_to_suffixes(:tests), do: ["_test.md"]
  defp phase_to_suffixes(:code), do: ["_code.md"]

  defp cleanup_prompt_directory(external_id, working_dir) do
    dir = resolve_prompt_dir(external_id, working_dir)

    if File.exists?(dir) and File.dir?(dir) do
      case File.ls(dir) do
        {:ok, []} -> File.rmdir(dir)
        _ -> :ok
      end
    end

    :ok
  end

  defp resolve_prompt_dir(external_id, nil), do: prompt_dir(external_id)

  defp resolve_prompt_dir(external_id, working_dir) do
    Path.join(working_dir, prompt_dir(external_id))
  end

  defp build_feedback(incomplete_phases, external_id) do
    phases_text =
      Enum.map_join(incomplete_phases, "\n\n", fn {phase, status} ->
        case status do
          {:missing, components} ->
            component_list = Enum.map_join(components, "\n  ", & &1.name)
            "**#{format_phase_name(phase)}**: Missing for:\n  #{component_list}"

          _ ->
            "**#{format_phase_name(phase)}**: Incomplete"
        end
      end)

    """
    The following lifecycle phases are incomplete:

    #{phases_text}

    Please complete the pending phases. Prompt files are located in:
    #{prompt_dir(external_id)}/

    - For spec prompts: invoke `@"CodeMySpec:spec-writer (agent)"`
    - For test prompts: invoke `@"CodeMySpec:test-writer (agent)"`
    - For code prompts: invoke `@"CodeMySpec:code-writer (agent)"`
    """
  end
end
