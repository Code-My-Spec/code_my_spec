defmodule CodeMySpec.AgentTasks.DevelopLiveContext do
  @moduledoc """
  Orchestrates the full lifecycle of a live context from specification through implementation.

  A live context is a spec-only grouping (no code file) containing LiveViews and
  LiveComponents. The parent live_context gets a spec but no implementation.

  Three phases:
  1. **Live context spec** (LiveContextSpec) — define the grouping, list views and components
  2. **Child specs** — spec each child view/component (type-aware dispatch)
  3. **Implementation** — tests + code for children only (LiveComponents first, then LiveViews)

  The parent live_context is NOT included in the implementation phase since it has no code.

  Writes prompt files to `.code_my_spec/status/{root}/{live_context}/`.
  """

  require Logger

  alias CodeMySpec.Components.ComponentRepository

  alias CodeMySpec.AgentTasks.{
    ComponentCode,
    ComponentSpec,
    ComponentTest,
    LiveContextSpec,
    LiveViewCode,
    LiveViewSpec,
    LiveViewTest
  }

  @status_dir CodeMySpec.Paths.status_dir()

  defp live_context_status_dir(component) do
    parts =
      component.module_name
      |> String.split(".")
      |> Enum.map(&Macro.underscore/1)

    {dir_parts, [dirname]} = Enum.split(parts, -1)
    Path.join([@status_dir | dir_parts] ++ [dirname])
  end

  @doc """
  Generate prompt files and orchestration instructions for the full live context lifecycle.

  Returns {:ok, prompt_text}
  """
  def command(scope, session, _opts \\ []) do
    %{component: live_context} = session
    live_context = ComponentRepository.get_component(scope, live_context.id)
    status_dir = live_context_status_dir(live_context)

    with {:ok, children} <- get_child_components(scope, live_context),
         {:ok, phase_status} <-
           check_lifecycle_phases(scope, session, live_context, children),
         {:ok, prompt_files} <-
           generate_phase_prompts(scope, session, live_context, children, phase_status, status_dir) do
      {:ok, orchestration_content} =
        build_orchestration_prompt(live_context, phase_status, prompt_files, status_dir)

      orchestration_path = "#{status_dir}/develop_live_context.md"

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
  Validate all lifecycle phases are complete for the live context.

  Returns:
  - {:ok, :valid} if all phases pass
  - {:ok, :invalid, feedback} if some phases are incomplete
  """
  def evaluate(scope, session, _opts \\ []) do
    %{component: live_context} = session

    Logger.info(
      "[DevelopLiveContext] evaluate called for: #{live_context.name} (#{live_context.module_name})"
    )

    live_context = ComponentRepository.get_component(scope, live_context.id)
    status_dir = live_context_status_dir(live_context)
    working_dir = scope.environment && scope.environment.cwd

    with {:ok, children} <- get_child_components(scope, live_context),
         {:ok, phase_status} <-
           check_lifecycle_phases(scope, session, live_context, children),
         :ok <- cleanup_completed_phases(phase_status, status_dir, working_dir) do
      handle_phase_result(phase_status, scope, session, live_context, children, status_dir, working_dir)
    end
  end

  defp handle_phase_result(%{complete: true}, _scope, _session, _component, _children, status_dir, working_dir) do
    Logger.info("[DevelopLiveContext] All phases complete")
    cleanup_status_directory(status_dir, working_dir)
    {:ok, :valid}
  end

  defp handle_phase_result(%{incomplete_phases: incomplete} = phase_status, scope, session, live_context, children, status_dir, _working_dir) do
    phase_names =
      Enum.map_join(incomplete, ", ", fn {phase, _} -> Atom.to_string(phase) end)

    Logger.info("[DevelopLiveContext] Incomplete phases: #{phase_names}")

    {:ok, prompt_files} =
      generate_phase_prompts(scope, session, live_context, children, phase_status, status_dir)

    {:ok, orchestration_content} =
      build_orchestration_prompt(live_context, phase_status, prompt_files, status_dir)

    orchestration_path = "#{status_dir}/develop_live_context.md"

    CodeMySpec.Environments.write_file(
      scope.environment,
      orchestration_path,
      orchestration_content
    )

    feedback = build_feedback(live_context, incomplete, status_dir)
    {:ok, :invalid, feedback}
  end

  # ============================================================================
  # Phase Checking
  # ============================================================================

  defp get_child_components(scope, live_context) do
    children = ComponentRepository.list_all_descendants(scope, live_context.id)
    {:ok, children}
  end

  defp check_lifecycle_phases(scope, session, live_context, children) do
    context_spec_status = check_context_spec(scope, session, live_context)
    child_specs_status = check_child_specs(scope, session, children)
    # Only children get implementation — parent live_context has no code
    implementation_status = check_implementation(scope, children)

    incomplete_phases =
      []
      |> maybe_add_phase(:live_context_spec, context_spec_status)
      |> maybe_add_phase(:child_specs, child_specs_status)
      |> maybe_add_phase(:implementation, implementation_status)

    status =
      if Enum.empty?(incomplete_phases) do
        %{complete: true}
      else
        %{
          complete: false,
          incomplete_phases: incomplete_phases,
          live_context_spec: context_spec_status,
          child_specs: child_specs_status,
          implementation: implementation_status
        }
      end

    {:ok, status}
  end

  defp maybe_add_phase(phases, _name, :complete), do: phases
  defp maybe_add_phase(phases, name, status), do: [{name, status} | phases]

  defp check_context_spec(scope, session, live_context) do
    child_session = %{component: live_context, project: session.project}

    case LiveContextSpec.evaluate(scope, child_session) do
      {:ok, :valid} -> :complete
      _ -> {:missing, [live_context]}
    end
  end

  defp check_child_specs(scope, session, children) do
    missing =
      Enum.filter(children, fn child ->
        child_session = %{component: child, project: session.project}
        spec_module = spec_module_for(child)

        case spec_module.evaluate(scope, child_session) do
          {:ok, :valid} -> false
          _ -> true
        end
      end)

    if Enum.empty?(missing), do: :complete, else: {:missing, missing}
  end

  # Only check implementation for children — parent has no code
  defp check_implementation(scope, children) do
    components_with_needs =
      children
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
      :complete
    else
      {:missing, components_with_needs}
    end
  end

  # ============================================================================
  # Spec Module Dispatch
  # ============================================================================

  defp spec_module_for(%{type: type}) when type in ["liveview", "liveview_component"],
    do: LiveViewSpec

  defp spec_module_for(_), do: ComponentSpec

  # ============================================================================
  # Prompt Generation
  # ============================================================================

  defp generate_phase_prompts(scope, session, live_context, _children, phase_status, status_dir) do
    environment = scope.environment

    ctx = %{
      scope: scope,
      session: session,
      live_context: live_context,
      environment: environment,
      status_dir: status_dir
    }

    prompt_files =
      []
      |> maybe_add_context_spec_prompts(phase_status, ctx)
      |> maybe_add_child_spec_prompts(phase_status, ctx)
      |> maybe_add_implementation_prompts(phase_status, ctx)

    {:ok, prompt_files}
  end

  defp maybe_add_context_spec_prompts(acc, %{live_context_spec: {:missing, _}}, ctx) do
    acc ++ generate_context_spec_prompt(ctx)
  end

  defp maybe_add_context_spec_prompts(acc, _status, _ctx), do: acc

  defp maybe_add_child_spec_prompts(acc, %{child_specs: {:missing, missing}}, ctx) do
    acc ++ generate_child_spec_prompts(ctx, missing)
  end

  defp maybe_add_child_spec_prompts(acc, _status, _ctx), do: acc

  defp maybe_add_implementation_prompts(
         acc,
         %{
           live_context_spec: :complete,
           child_specs: :complete,
           implementation: {:missing, components_with_needs}
         },
         ctx
       ) do
    acc ++ generate_implementation_prompts(ctx, components_with_needs)
  end

  defp maybe_add_implementation_prompts(acc, _status, _ctx), do: acc

  defp generate_context_spec_prompt(ctx) do
    child_session = %{component: ctx.live_context, project: ctx.session.project}
    {:ok, prompt_content} = LiveContextSpec.command(ctx.scope, child_session)

    safe_name = safe_filename(ctx.live_context.module_name)
    file_path = "#{ctx.status_dir}/#{safe_name}_live_context_spec.md"
    :ok = CodeMySpec.Environments.write_file(ctx.environment, file_path, prompt_content)

    [
      %{
        component: ctx.live_context,
        file_path: file_path,
        prompt_type: :live_context_spec,
        phase: 1
      }
    ]
  end

  defp generate_child_spec_prompts(ctx, children) do
    Enum.map(children, fn child ->
      child_session = %{component: child, project: ctx.session.project}
      spec_module = spec_module_for(child)
      {:ok, prompt_content} = spec_module.command(ctx.scope, child_session)

      safe_name = safe_filename(child.module_name)
      file_path = "#{ctx.status_dir}/#{safe_name}_child_spec.md"
      :ok = CodeMySpec.Environments.write_file(ctx.environment, file_path, prompt_content)

      %{component: child, file_path: file_path, prompt_type: :child_spec, phase: 2}
    end)
  end

  defp generate_implementation_prompts(ctx, components_with_needs) do
    Enum.flat_map(components_with_needs, fn {component, needs} ->
      child_session = %{component: component, project: ctx.session.project}
      safe_name = safe_filename(component.module_name)

      test_prompts = maybe_generate_test_prompt(ctx, child_session, component, safe_name, needs)
      code_prompts = maybe_generate_code_prompt(ctx, child_session, component, safe_name, needs)

      test_prompts ++ code_prompts
    end)
  end

  defp maybe_generate_test_prompt(ctx, session, component, safe_name, needs) do
    if :test in needs do
      {:ok, content} = test_command(ctx.scope, session, component.type)
      file_path = "#{ctx.status_dir}/#{safe_name}_test.md"
      :ok = CodeMySpec.Environments.write_file(ctx.environment, file_path, content)
      [%{component: component, file_path: file_path, prompt_type: :test, phase: 3}]
    else
      []
    end
  end

  defp maybe_generate_code_prompt(ctx, session, component, safe_name, needs) do
    if :code in needs do
      {:ok, content} = code_command(ctx.scope, session, component.type)
      file_path = "#{ctx.status_dir}/#{safe_name}_code.md"
      :ok = CodeMySpec.Environments.write_file(ctx.environment, file_path, content)
      [%{component: component, file_path: file_path, prompt_type: :code, phase: 3}]
    else
      []
    end
  end

  # LiveViews use LiveViewTest/LiveViewCode
  defp test_command(scope, session, "liveview"), do: LiveViewTest.command(scope, session)
  defp test_command(scope, session, _type), do: ComponentTest.command(scope, session)

  defp code_command(scope, session, "liveview"), do: LiveViewCode.command(scope, session)
  defp code_command(scope, session, _type), do: ComponentCode.command(scope, session)

  defp safe_filename(module_name) do
    module_name
    |> String.replace(".", "_")
    |> String.downcase()
  end

  # ============================================================================
  # Orchestration Prompt
  # ============================================================================

  defp build_orchestration_prompt(_live_context, %{complete: true}, _prompt_files, _status_dir) do
    {:ok,
     """
     Live context lifecycle is complete. All phases have passed:
     - Live context specification
     - Child specifications
     - Implementation

     No further action required.
     """}
  end

  defp build_orchestration_prompt(live_context, phase_status, prompt_files, _status_dir) do
    current_phase = determine_current_phase(phase_status)
    phase_text = format_phase_instructions(current_phase, prompt_files)

    {:ok,
     """
     # Live Context Lifecycle: #{live_context.name}

     You are orchestrating the full development lifecycle for this live context.

     ## Lifecycle Phases

     1. **Live Context Spec** - Define the grouping, list child views and components
     2. **Child Specs** - Design each child LiveView and LiveComponent
     3. **Implementation** - Tests + code for children only (LiveComponents first, then LiveViews)

     **Note:** The parent live context has no code file — only children are implemented.

     ## Current Phase: #{format_phase_name(current_phase)}

     #{phase_text}

     ## Subagent Usage

     Invoke the appropriate subagent for each prompt file:

     - For spec prompts: `@"CodeMySpec:spec-writer (agent)"`
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
      match?({:missing, _}, phase_status[:live_context_spec]) -> :live_context_spec
      match?({:missing, _}, phase_status[:child_specs]) -> :child_specs
      match?({:missing, _}, phase_status[:implementation]) -> :implementation
      true -> :complete
    end
  end

  defp format_phase_name(:live_context_spec), do: "Live Context Specification"
  defp format_phase_name(:child_specs), do: "Child Specifications"
  defp format_phase_name(:implementation), do: "Implementation"
  defp format_phase_name(:complete), do: "Complete"

  defp format_phase_instructions(:implementation, prompt_files) do
    phase_files = Enum.filter(prompt_files, fn pf -> pf.phase == 3 end)

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
        |> Enum.sort_by(&component_sort_order/1)

      component_tasks = Enum.map_join(by_component, "\n", &format_component_task/1)

      """
      Implement in dependency order:
      - **LiveComponents** first (shared components have no cross-dependencies)
      - **LiveViews** last (compose and use the shared components)

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

  # LiveComponents first (shared), then LiveViews (compose them)
  defp component_sort_order({comp, _, _}) do
    if comp.type == "liveview_component", do: 0, else: 1
  end

  defp phase_to_number(:live_context_spec), do: 1
  defp phase_to_number(:child_specs), do: 2
  defp phase_to_number(:child_spec), do: 2
  defp phase_to_number(:implementation), do: 3
  defp phase_to_number(_), do: 0

  # ============================================================================
  # Cleanup
  # ============================================================================

  defp cleanup_completed_phases(phase_status, status_dir, working_dir) do
    completed_suffixes =
      if phase_status[:complete] == true do
        [:live_context_spec, :child_specs, :implementation]
        |> Enum.flat_map(&phase_to_suffixes/1)
      else
        [:live_context_spec, :child_specs, :implementation]
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

  defp phase_to_suffixes(:live_context_spec), do: ["_live_context_spec.md"]
  defp phase_to_suffixes(:child_specs), do: ["_child_spec.md"]
  defp phase_to_suffixes(:implementation), do: ["_test.md", "_code.md"]

  defp cleanup_status_directory(status_dir, working_dir) do
    dir = resolve_dir(status_dir, working_dir)

    if File.exists?(dir) and File.dir?(dir) do
      File.rm_rf(dir)
    end

    :ok
  end

  defp resolve_dir(status_dir, nil), do: status_dir
  defp resolve_dir(status_dir, working_dir), do: Path.join(working_dir, status_dir)

  defp build_feedback(live_context, incomplete_phases, status_dir) do
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
    Live context "#{live_context.name}" (#{live_context.module_name}) has incomplete phases:
    #{phases_text}

    Read your updated instructions at `#{status_dir}/develop_live_context.md` and complete the current phase.
    When you finish the phase, stop the session again so validation can advance you to the next phase.
    """
  end
end
