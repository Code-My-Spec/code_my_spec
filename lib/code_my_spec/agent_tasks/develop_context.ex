defmodule CodeMySpec.AgentTasks.DevelopContext do
  @moduledoc """
  Orchestrates the full lifecycle of a context from specification through implementation.

  Writes prompt files to `.code_my_spec/status/{root}/{context}/` — the same directory tree
  that StatusWriter uses for status markdown. StatusWriter owns the `.md` status file
  (e.g. `.code_my_spec/status/metric_flow/accounts.md`); this module owns the action directory
  (e.g. `.code_my_spec/status/metric_flow/accounts/develop_context.md` + prompt files).

  Paths are derived from the context component's module_name, making the whole
  thing idempotent — same context always produces the same file paths regardless
  of which session invokes it.

  Lifecycle phases:
  1. Context spec (ContextSpec)
  2. Component specs (ComponentSpec) for each child
  3. Design review (ContextDesignReview)
  4. Implementation (tests + code per component in dependency order)

  Two main functions:
  - `command/3` - Generates prompt files for incomplete phases, returns orchestration prompt
  - `evaluate/3` - Validates all phases complete and cleans up prompt files
  """

  require Logger

  alias CodeMySpec.Components.ComponentRepository

  alias CodeMySpec.AgentTasks.{
    ComponentCode,
    ComponentSpec,
    ComponentTest,
    ContextDesignReview,
    ContextSpec
  }

  @status_dir CodeMySpec.Paths.status_dir()

  # Derive an action directory from the context component's module_name.
  # MetricFlow.Accounts → .code_my_spec/status/metric_flow/accounts
  # Sits alongside the StatusWriter file (metric_flow/accounts.md).
  defp context_status_dir(context_component) do
    parts =
      context_component.module_name
      |> String.split(".")
      |> Enum.map(&Macro.underscore/1)

    {dir_parts, [dirname]} = Enum.split(parts, -1)
    Path.join([@status_dir | dir_parts] ++ [dirname])
  end

  @doc """
  Generate prompt files and orchestration instructions for the full context lifecycle.

  Checks each phase (spec, design review, implementation) and generates prompt files
  for incomplete phases. Files are written to `.code_my_spec/status/{root}/{context}/`.

  Returns {:ok, prompt_text}
  """
  def command(scope, session, _opts \\ []) do
    %{component: context_component} = session
    context_component = ComponentRepository.get_component(scope, context_component.id)
    status_dir = context_status_dir(context_component)

    with {:ok, children} <- get_child_components(scope, context_component),
         {:ok, phase_status} <-
           check_lifecycle_phases(scope, session, context_component, children),
         {:ok, prompt_files} <-
           generate_phase_prompts(
             scope,
             session,
             context_component,
             children,
             phase_status,
             status_dir
           ) do
      {:ok, orchestration_content} =
        build_orchestration_prompt(context_component, phase_status, prompt_files, status_dir)

      orchestration_path = "#{status_dir}/develop_context.md"

      CodeMySpec.Environments.write_file(
        scope.environment,
        orchestration_path,
        orchestration_content
      )

      {:ok,
       "Your instructions have been written to: `#{orchestration_path}`\n\nRead this file to begin."}
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

    Logger.info(
      "[DevelopContext] evaluate called for context: #{context_component.name} (#{context_component.module_name})"
    )

    context_component = ComponentRepository.get_component(scope, context_component.id)
    status_dir = context_status_dir(context_component)
    working_dir = scope.environment && scope.environment.cwd

    with {:ok, children} <- get_child_components(scope, context_component),
         {:ok, phase_status} <-
           check_lifecycle_phases(scope, session, context_component, children),
         :ok <- cleanup_completed_phases(phase_status, status_dir, working_dir) do
      handle_phase_result(phase_status, scope, session, context_component, children, status_dir, working_dir)
    end
  end

  defp handle_phase_result(%{complete: true}, _scope, _session, _component, _children, status_dir, working_dir) do
    Logger.info("[DevelopContext] All phases complete")
    cleanup_status_directory(status_dir, working_dir)
    {:ok, :valid}
  end

  defp handle_phase_result(%{incomplete_phases: incomplete} = phase_status, scope, session, context_component, children, status_dir, _working_dir) do
    phase_names =
      Enum.map_join(incomplete, ", ", fn {phase, _} -> Atom.to_string(phase) end)

    Logger.info("[DevelopContext] Incomplete phases: #{phase_names}")

    {:ok, prompt_files} =
      generate_phase_prompts(scope, session, context_component, children, phase_status, status_dir)

    Logger.info("[DevelopContext] Generated #{length(prompt_files)} prompt file(s)")

    {:ok, orchestration_content} =
      build_orchestration_prompt(context_component, phase_status, prompt_files, status_dir)

    orchestration_path = "#{status_dir}/develop_context.md"

    CodeMySpec.Environments.write_file(
      scope.environment,
      orchestration_path,
      orchestration_content
    )

    feedback = build_feedback(context_component, incomplete, status_dir)
    {:ok, :invalid, feedback}
  end

  # Private functions - Phase checking

  defp get_child_components(scope, context_component) do
    children = ComponentRepository.list_all_descendants(scope, context_component.id)
    {:ok, children}
  end

  defp check_lifecycle_phases(scope, session, context_component, children) do
    context_spec_status = check_context_spec(scope, session, context_component)
    component_specs_status = check_component_specs(scope, session, children)
    design_review_status = check_design_review(scope, session, context_component)
    implementation_status = check_implementation(scope, session, [context_component | children])

    incomplete_phases =
      []
      |> maybe_add_phase(:context_spec, context_spec_status)
      |> maybe_add_phase(:component_specs, component_specs_status)
      |> maybe_add_phase(:design_review, design_review_status)
      |> maybe_add_phase(:implementation, implementation_status)

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
          implementation: implementation_status
        }
      end

    {:ok, status}
  end

  defp maybe_add_phase(phases, _name, :complete), do: phases
  defp maybe_add_phase(phases, name, status), do: [{name, status} | phases]

  defp check_context_spec(scope, session, context_component) do
    child_session = %{component: context_component, project: session.project}

    case ContextSpec.evaluate(scope, child_session) do
      {:ok, :valid} -> :complete
      _ -> {:missing, [context_component]}
    end
  end

  defp check_component_specs(scope, session, children) do
    missing =
      Enum.filter(children, fn child ->
        child_session = %{component: child, project: session.project}

        case ComponentSpec.evaluate(scope, child_session) do
          {:ok, :valid} -> false
          _ -> true
        end
      end)

    if Enum.empty?(missing), do: :complete, else: {:missing, missing}
  end

  defp check_design_review(scope, session, context_component) do
    child_session = %{component: context_component, project: session.project}

    case ContextDesignReview.evaluate(scope, child_session) do
      {:ok, :valid} -> :complete
      _ -> {:missing, [context_component]}
    end
  end

  defp check_implementation(scope, _session, components) do
    Logger.info(
      "[DevelopContext] check_implementation: evaluating #{length(components)} component(s)"
    )

    components_with_needs =
      components
      |> Enum.map(fn component ->
        requirements = component.requirements || []

        test_results =
          CodeMySpec.Requirements.check_requirements(
            scope,
            component,
            requirements,
            artifact_types: [:tests]
          )

        code_results =
          CodeMySpec.Requirements.check_requirements(
            scope,
            component,
            requirements,
            artifact_types: [:code]
          )

        needs_tests = Enum.any?(test_results, fn r -> not r.satisfied end)
        needs_code = Enum.any?(code_results, fn r -> not r.satisfied end)

        needs =
          if(needs_tests, do: [:test], else: []) ++
            if(needs_code, do: [:code], else: [])

        {component, needs}
      end)
      |> Enum.filter(fn {_component, needs} -> needs != [] end)

    if Enum.empty?(components_with_needs) do
      Logger.info("[DevelopContext] check_implementation: all complete")
      :complete
    else
      for {comp, needs} <- components_with_needs do
        Logger.info(
          "[DevelopContext] check_implementation: #{comp.module_name} needs #{inspect(needs)}"
        )
      end

      {:missing, components_with_needs}
    end
  end

  # Private functions - Prompt generation

  defp generate_phase_prompts(
         scope,
         session,
         context_component,
         _children,
         phase_status,
         status_dir
       ) do
    environment = scope.environment

    ctx = %{
      scope: scope,
      session: session,
      context_component: context_component,
      environment: environment,
      status_dir: status_dir
    }

    prompt_files =
      []
      |> maybe_add_context_spec_prompts(phase_status, ctx)
      |> maybe_add_component_spec_prompts(phase_status, ctx)
      |> maybe_add_design_review_prompts(phase_status, ctx)
      |> maybe_add_implementation_prompts(phase_status, ctx)

    {:ok, prompt_files}
  end

  defp maybe_add_context_spec_prompts(acc, %{context_spec: {:missing, _}} = _status, ctx) do
    acc ++
      generate_context_spec_prompt(
        ctx.scope,
        ctx.session,
        ctx.context_component,
        ctx.environment,
        ctx.status_dir
      )
  end

  defp maybe_add_context_spec_prompts(acc, _status, _ctx), do: acc

  defp maybe_add_component_spec_prompts(acc, %{component_specs: {:missing, missing}}, ctx) do
    acc ++
      generate_component_spec_prompts(
        ctx.scope,
        ctx.session,
        missing,
        ctx.environment,
        ctx.status_dir
      )
  end

  defp maybe_add_component_spec_prompts(acc, _status, _ctx), do: acc

  defp maybe_add_design_review_prompts(
         acc,
         %{context_spec: :complete, component_specs: :complete, design_review: {:missing, _}},
         ctx
       ) do
    acc ++
      generate_design_review_prompt(
        ctx.scope,
        ctx.session,
        ctx.context_component,
        ctx.environment,
        ctx.status_dir
      )
  end

  defp maybe_add_design_review_prompts(acc, _status, _ctx), do: acc

  defp maybe_add_implementation_prompts(
         acc,
         %{design_review: :complete, implementation: {:missing, components_with_needs}},
         ctx
       ) do
    acc ++
      generate_implementation_prompts(
        ctx.scope,
        ctx.session,
        components_with_needs,
        ctx.environment,
        ctx.status_dir
      )
  end

  defp maybe_add_implementation_prompts(acc, _status, _ctx), do: acc

  defp generate_context_spec_prompt(scope, session, context_component, environment, status_dir) do
    child_session = %{component: context_component, project: session.project}
    {:ok, prompt_content} = ContextSpec.command(scope, child_session)

    safe_name = safe_filename(context_component.module_name)
    file_path = "#{status_dir}/#{safe_name}_context_spec.md"
    :ok = CodeMySpec.Environments.write_file(environment, file_path, prompt_content)

    [%{component: context_component, file_path: file_path, prompt_type: :context_spec, phase: 1}]
  end

  defp generate_component_spec_prompts(scope, session, children, environment, status_dir) do
    Enum.map(children, fn child ->
      child_session = %{component: child, project: session.project}
      {:ok, prompt_content} = ComponentSpec.command(scope, child_session)

      safe_name = safe_filename(child.module_name)
      file_path = "#{status_dir}/#{safe_name}_component_spec.md"
      :ok = CodeMySpec.Environments.write_file(environment, file_path, prompt_content)

      %{component: child, file_path: file_path, prompt_type: :component_spec, phase: 2}
    end)
  end

  defp generate_design_review_prompt(scope, session, context_component, environment, status_dir) do
    child_session = %{component: context_component, project: session.project}
    {:ok, prompt_content} = ContextDesignReview.command(scope, child_session)

    safe_name = safe_filename(context_component.module_name)
    file_path = "#{status_dir}/#{safe_name}_design_review.md"
    :ok = CodeMySpec.Environments.write_file(environment, file_path, prompt_content)

    [%{component: context_component, file_path: file_path, prompt_type: :design_review, phase: 3}]
  end

  defp generate_implementation_prompts(
         scope,
         session,
         components_with_needs,
         environment,
         status_dir
       ) do
    Enum.flat_map(components_with_needs, fn {component, needs} ->
      child_session = %{component: component, project: session.project}
      safe_name = safe_filename(component.module_name)

      test_prompts =
        if :test in needs do
          {:ok, prompt_content} = ComponentTest.command(scope, child_session)
          file_path = "#{status_dir}/#{safe_name}_test.md"
          :ok = CodeMySpec.Environments.write_file(environment, file_path, prompt_content)
          [%{component: component, file_path: file_path, prompt_type: :test, phase: 4}]
        else
          []
        end

      code_prompts =
        if :code in needs do
          {:ok, prompt_content} = ComponentCode.command(scope, child_session)
          file_path = "#{status_dir}/#{safe_name}_code.md"
          :ok = CodeMySpec.Environments.write_file(environment, file_path, prompt_content)
          [%{component: component, file_path: file_path, prompt_type: :code, phase: 4}]
        else
          []
        end

      test_prompts ++ code_prompts
    end)
  end

  defp safe_filename(module_name) do
    module_name
    |> String.replace(".", "_")
    |> String.downcase()
  end

  # Private functions - Prompt building

  defp build_orchestration_prompt(
         _context_component,
         %{complete: true},
         _prompt_files,
         _status_dir
       ) do
    {:ok,
     """
     Context lifecycle is complete. All phases have passed:
     - Context specification
     - Component specifications
     - Design review
     - Implementation

     No further action required.
     """}
  end

  defp build_orchestration_prompt(context_component, phase_status, prompt_files, _status_dir) do
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
     4. **Implementation** - Tests + code per component in dependency order

     ## Current Phase: #{format_phase_name(current_phase)}

     #{phase_text}

     ## Subagent Usage

     Invoke the appropriate subagent for each prompt file:

     - For spec prompts: `@"CodeMySpec:spec-writer (agent)"`
     - For design review prompts: `@"CodeMySpec:spec-writer (agent)"`
     - For test prompts: `@"CodeMySpec:test-writer (agent)"`
     - For code prompts: `@"CodeMySpec:code-writer (agent)"`

     ## Workflow

     1. Complete all tasks listed above for the current phase
     2. **Stop the session** — end your turn so the stop hook can validate your work
     3. The stop hook will check your progress and provide instructions for the next phase
     4. If the hook blocks the stop, follow its feedback and repeat from step 1

     **Important:** You must stop after completing each phase. Do not attempt to
     continue to the next phase on your own — the stop hook generates the prompt
     files you need for each subsequent phase.
     """}
  end

  defp determine_current_phase(phase_status) do
    cond do
      match?({:missing, _}, phase_status[:context_spec]) -> :context_spec
      match?({:missing, _}, phase_status[:component_specs]) -> :component_specs
      match?({:missing, _}, phase_status[:design_review]) -> :design_review
      match?({:missing, _}, phase_status[:implementation]) -> :implementation
      true -> :complete
    end
  end

  defp format_phase_name(:context_spec), do: "Context Specification"
  defp format_phase_name(:component_specs), do: "Component Specifications"
  defp format_phase_name(:design_review), do: "Design Review"
  defp format_phase_name(:implementation), do: "Implementation"
  defp format_phase_name(:complete), do: "Complete"

  defp format_phase_instructions(:implementation, prompt_files) do
    phase_files = Enum.filter(prompt_files, fn pf -> pf.phase == 4 end)

    if Enum.empty?(phase_files) do
      "No prompt files generated for this phase."
    else
      by_component =
        phase_files
        |> Enum.group_by(& &1.component.id)
        |> Enum.map(fn {_id, files} ->
          component = hd(files).component
          test_file = Enum.find(files, &(&1.prompt_type == :test))
          code_file = Enum.find(files, &(&1.prompt_type == :code))
          {component, test_file, code_file}
        end)
        |> Enum.sort_by(fn {comp, _, _} -> comp.name end)

      component_tasks = Enum.map_join(by_component, "\n", &format_component_task/1)

      """
      Implement in dependency order:
      - **Schemas** first (no dependencies)
      - **Repositories** next (depend on schemas)
      - **Services/Logic** (depend on repositories and schemas)
      - **Context module** last (delegates to and coordinates all the above)

      For each component: write tests first, then implement code. Verify tests pass before moving to the next component.

      Components to implement:

      #{component_tasks}

      For each component, invoke the appropriate subagent with the prompt file:
      - Test prompts: `@"CodeMySpec:test-writer (agent)"`
      - Code prompts: `@"CodeMySpec:code-writer (agent)"`
      """
    end
  end

  defp format_phase_instructions(phase, prompt_files) do
    phase_files =
      Enum.filter(prompt_files, fn pf ->
        pf.prompt_type == phase or pf.phase == phase_to_number(phase)
      end)

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

  defp format_component_task({component, test_file, code_file}) do
    test_line =
      if test_file,
        do: "  - [ ] Test: `#{test_file.file_path}`",
        else: "  - [x] Tests: passing"

    code_line =
      if code_file,
        do: "  - [ ] Code: `#{code_file.file_path}`",
        else: "  - [x] Code: passing"

    "- **#{component.name}** (#{component.type})\n#{test_line}\n#{code_line}"
  end

  defp phase_to_number(:context_spec), do: 1
  defp phase_to_number(:component_specs), do: 2
  defp phase_to_number(:component_spec), do: 2
  defp phase_to_number(:design_review), do: 3
  defp phase_to_number(:implementation), do: 4
  defp phase_to_number(_), do: 0

  # Private functions - Cleanup

  defp cleanup_completed_phases(phase_status, status_dir, working_dir) do
    completed_suffixes =
      if phase_status[:complete] == true do
        [:context_spec, :component_specs, :design_review, :implementation]
        |> Enum.flat_map(&phase_to_suffixes/1)
      else
        [:context_spec, :component_specs, :design_review, :implementation]
        |> Enum.filter(fn phase -> phase_status[phase] == :complete end)
        |> Enum.flat_map(&phase_to_suffixes/1)
      end

    dir = resolve_dir(status_dir, working_dir)

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
  defp phase_to_suffixes(:implementation), do: ["_test.md", "_code.md"]

  # When all phases complete, remove the entire status directory for this context.
  # The status .md file (owned by StatusWriter) remains — only action files are cleaned.
  defp cleanup_status_directory(status_dir, working_dir) do
    dir = resolve_dir(status_dir, working_dir)

    if File.exists?(dir) and File.dir?(dir) do
      File.rm_rf(dir)
    end

    :ok
  end

  defp resolve_dir(status_dir, nil), do: status_dir
  defp resolve_dir(status_dir, working_dir), do: Path.join(working_dir, status_dir)

  defp build_feedback(context_component, incomplete_phases, status_dir) do
    phases_text =
      Enum.map_join(incomplete_phases, "\n", fn {phase, status} ->
        case status do
          {:missing, items} ->
            names =
              Enum.map_join(items, ", ", fn
                {component, _needs} -> component.name
                component -> component.name
              end)

            "- #{format_phase_name(phase)}: #{names}"

          _ ->
            "- #{format_phase_name(phase)}: incomplete"
        end
      end)

    """
    Context "#{context_component.name}" (#{context_component.module_name}) has incomplete phases:
    #{phases_text}

    Read your updated instructions at `#{status_dir}/develop_context.md` and complete the current phase.
    When you finish the phase, stop the session again so validation can advance you to the next phase.
    """
  end
end
