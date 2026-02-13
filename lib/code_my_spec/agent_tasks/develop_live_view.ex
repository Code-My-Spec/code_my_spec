defmodule CodeMySpec.AgentTasks.DevelopLiveView do
  @moduledoc """
  Orchestrates the full lifecycle of a LiveView from specification through implementation.

  Mirrors DevelopContext's phased approach adapted for LiveView components:
  spec the LiveView, spec child components, run design review, then implement
  (tests + code) in dependency order — child components first, then the parent
  LiveView that composes them.

  Uses LiveViewSpec/LiveViewTest/LiveViewCode for the parent LiveView and
  ComponentSpec/ComponentTest/ComponentCode for child components.

  Writes prompt files to `docs/status/{root}/{live_view}/` — the same directory
  tree that StatusWriter uses for status markdown. Paths are derived from the
  component's module_name, making the whole thing idempotent.

  Lifecycle phases:
  1. LiveView spec (LiveViewSpec)
  2. Component specs (ComponentSpec) for each child
  3. Design review (ContextDesignReview)
  4. Implementation (LiveViewTest + LiveViewCode for parent,
     ComponentTest + ComponentCode for children in dependency order)

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
    LiveViewCode,
    LiveViewSpec,
    LiveViewTest
  }

  @status_dir "docs/status"

  # Derive an action directory from the LiveView component's module_name.
  # TestAppWeb.DashboardLive → docs/status/test_app_web/dashboard_live
  defp liveview_status_dir(liveview_component) do
    parts =
      liveview_component.module_name
      |> String.split(".")
      |> Enum.map(&Macro.underscore/1)

    {dir_parts, [dirname]} = Enum.split(parts, -1)
    Path.join([@status_dir | dir_parts] ++ [dirname])
  end

  @doc """
  Generate prompt files and orchestration instructions for the full LiveView lifecycle.

  Checks each phase (spec, design review, implementation) and generates prompt files
  for incomplete phases. Files are written to `docs/status/{root}/{live_view}/`.

  Returns {:ok, prompt_text}
  """
  def command(scope, session, _opts \\ []) do
    %{component: liveview_component} = session
    liveview_component = ComponentRepository.get_component(scope, liveview_component.id)
    status_dir = liveview_status_dir(liveview_component)

    with {:ok, children} <- get_child_components(scope, liveview_component),
         {:ok, phase_status} <- check_lifecycle_phases(scope, session, liveview_component, children),
         {:ok, prompt_files} <-
           generate_phase_prompts(scope, session, liveview_component, children, phase_status, status_dir) do
      {:ok, orchestration_content} =
        build_orchestration_prompt(liveview_component, phase_status, prompt_files, status_dir)

      orchestration_path = "#{status_dir}/develop_live_view.md"
      CodeMySpec.Environments.write_file(scope.environment, orchestration_path, orchestration_content)

      {:ok, "Your instructions have been written to: `#{orchestration_path}`\n\nRead this file to begin."}
    end
  end

  @doc """
  Validate all lifecycle phases are complete for the LiveView.

  Returns:
  - {:ok, :valid} if all phases pass
  - {:ok, :invalid, feedback} if some phases are incomplete
  - {:error, reason} if evaluation failed
  """
  def evaluate(scope, session, _opts \\ []) do
    %{component: liveview_component} = session

    Logger.info(
      "[DevelopLiveView] evaluate called for LiveView: #{liveview_component.name} (#{liveview_component.module_name})"
    )

    liveview_component = ComponentRepository.get_component(scope, liveview_component.id)
    status_dir = liveview_status_dir(liveview_component)
    working_dir = scope.environment && scope.environment.cwd

    with {:ok, children} <- get_child_components(scope, liveview_component),
         {:ok, phase_status} <- check_lifecycle_phases(scope, session, liveview_component, children),
         :ok <- cleanup_completed_phases(phase_status, status_dir, working_dir) do
      case phase_status do
        %{complete: true} ->
          Logger.info("[DevelopLiveView] All phases complete")
          cleanup_status_directory(status_dir, working_dir)
          {:ok, :valid}

        %{incomplete_phases: incomplete} ->
          phase_names =
            Enum.map_join(incomplete, ", ", fn {phase, _} -> Atom.to_string(phase) end)

          Logger.info("[DevelopLiveView] Incomplete phases: #{phase_names}")

          {:ok, prompt_files} =
            generate_phase_prompts(
              scope,
              session,
              liveview_component,
              children,
              phase_status,
              status_dir
            )

          Logger.info("[DevelopLiveView] Generated #{length(prompt_files)} prompt file(s)")

          {:ok, orchestration_content} =
            build_orchestration_prompt(liveview_component, phase_status, prompt_files, status_dir)

          orchestration_path = "#{status_dir}/develop_live_view.md"

          CodeMySpec.Environments.write_file(
            scope.environment,
            orchestration_path,
            orchestration_content
          )

          feedback = build_feedback(liveview_component, incomplete, status_dir)
          {:ok, :invalid, feedback}
      end
    end
  end

  # Private functions - Phase checking

  defp get_child_components(scope, liveview_component) do
    children = ComponentRepository.list_all_descendants(scope, liveview_component.id)
    {:ok, children}
  end

  defp check_lifecycle_phases(scope, session, liveview_component, children) do
    liveview_spec_status = check_liveview_spec(scope, session, liveview_component)
    component_specs_status = check_component_specs(scope, session, children)
    design_review_status = check_design_review(scope, session, liveview_component)
    implementation_status = check_implementation(scope, liveview_component, children)

    incomplete_phases =
      []
      |> maybe_add_phase(:liveview_spec, liveview_spec_status)
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
          liveview_spec: liveview_spec_status,
          component_specs: component_specs_status,
          design_review: design_review_status,
          implementation: implementation_status
        }
      end

    {:ok, status}
  end

  defp maybe_add_phase(phases, _name, :complete), do: phases
  defp maybe_add_phase(phases, name, status), do: [{name, status} | phases]

  defp check_liveview_spec(scope, session, liveview_component) do
    child_session = %{component: liveview_component, project: session.project}

    case LiveViewSpec.evaluate(scope, child_session) do
      {:ok, :valid} -> :complete
      _ -> {:missing, [liveview_component]}
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

  defp check_design_review(scope, session, liveview_component) do
    # LiveView types don't have :review requirements in the Registry by default,
    # so ContextDesignReview.evaluate/3 would return :valid even without a review.
    # We check both: the evaluator for quality validation when requirements exist,
    # and file existence as a baseline gate.
    child_session = %{component: liveview_component, project: session.project}

    case ContextDesignReview.evaluate(scope, child_session) do
      {:ok, :valid} ->
        if review_file_exists?(scope, session, liveview_component) do
          :complete
        else
          {:missing, [liveview_component]}
        end

      _ ->
        {:missing, [liveview_component]}
    end
  end

  defp review_file_exists?(scope, session, component) do
    spec_path = CodeMySpec.Utils.component_files(component, session.project).spec_file
    review_path = String.replace_suffix(spec_path, ".spec.md", "/design_review.md")
    CodeMySpec.Environments.file_exists?(scope.environment, review_path)
  end

  defp check_implementation(scope, liveview_component, children) do
    all_components = [liveview_component | children]

    Logger.info(
      "[DevelopLiveView] check_implementation: evaluating #{length(all_components)} component(s)"
    )

    components_with_needs =
      all_components
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
          (if needs_tests, do: [:test], else: []) ++
            if(needs_code, do: [:code], else: [])

        {component, needs}
      end)
      |> Enum.filter(fn {_component, needs} -> needs != [] end)

    if Enum.empty?(components_with_needs) do
      Logger.info("[DevelopLiveView] check_implementation: all complete")
      :complete
    else
      for {comp, needs} <- components_with_needs do
        Logger.info(
          "[DevelopLiveView] check_implementation: #{comp.module_name} needs #{inspect(needs)}"
        )
      end

      {:missing, components_with_needs}
    end
  end

  # Private functions - Prompt generation

  defp generate_phase_prompts(
         scope,
         session,
         liveview_component,
         _children,
         phase_status,
         status_dir
       ) do
    environment = scope.environment

    ctx = %{
      scope: scope,
      session: session,
      liveview_component: liveview_component,
      environment: environment,
      status_dir: status_dir
    }

    prompt_files =
      []
      |> maybe_add_liveview_spec_prompts(phase_status, ctx)
      |> maybe_add_component_spec_prompts(phase_status, ctx)
      |> maybe_add_design_review_prompts(phase_status, ctx)
      |> maybe_add_implementation_prompts(phase_status, ctx)

    {:ok, prompt_files}
  end

  defp maybe_add_liveview_spec_prompts(acc, %{liveview_spec: {:missing, _}} = _status, ctx) do
    acc ++
      generate_liveview_spec_prompt(
        ctx.scope,
        ctx.session,
        ctx.liveview_component,
        ctx.environment,
        ctx.status_dir
      )
  end

  defp maybe_add_liveview_spec_prompts(acc, _status, _ctx), do: acc

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
         %{liveview_spec: :complete, component_specs: :complete, design_review: {:missing, _}},
         ctx
       ) do
    acc ++
      generate_design_review_prompt(
        ctx.scope,
        ctx.session,
        ctx.liveview_component,
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
        ctx.liveview_component,
        components_with_needs,
        ctx.environment,
        ctx.status_dir
      )
  end

  defp maybe_add_implementation_prompts(acc, _status, _ctx), do: acc

  defp generate_liveview_spec_prompt(scope, session, liveview_component, environment, status_dir) do
    child_session = %{component: liveview_component, project: session.project}
    {:ok, prompt_content} = LiveViewSpec.command(scope, child_session)

    safe_name = safe_filename(liveview_component.module_name)
    file_path = "#{status_dir}/#{safe_name}_live_view_spec.md"
    :ok = CodeMySpec.Environments.write_file(environment, file_path, prompt_content)

    [%{component: liveview_component, file_path: file_path, prompt_type: :liveview_spec, phase: 1}]
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

  defp generate_design_review_prompt(scope, session, liveview_component, environment, status_dir) do
    child_session = %{component: liveview_component, project: session.project}
    {:ok, prompt_content} = ContextDesignReview.command(scope, child_session)

    safe_name = safe_filename(liveview_component.module_name)
    file_path = "#{status_dir}/#{safe_name}_design_review.md"
    :ok = CodeMySpec.Environments.write_file(environment, file_path, prompt_content)

    [
      %{
        component: liveview_component,
        file_path: file_path,
        prompt_type: :design_review,
        phase: 3
      }
    ]
  end

  defp generate_implementation_prompts(
         scope,
         session,
         liveview_component,
         components_with_needs,
         environment,
         status_dir
       ) do
    Enum.flat_map(components_with_needs, fn {component, needs} ->
      child_session = %{component: component, project: session.project}
      safe_name = safe_filename(component.module_name)
      is_parent = component.id == liveview_component.id

      ctx = {scope, child_session, component, environment, status_dir, safe_name}
      test_prompts = maybe_generate_test_prompt(ctx, is_parent, needs)
      code_prompts = maybe_generate_code_prompt(ctx, is_parent, needs)

      test_prompts ++ code_prompts
    end)
  end

  defp maybe_generate_test_prompt({scope, session, component, env, dir, name}, is_parent, needs) do
    if :test in needs do
      {:ok, content} = test_command(scope, session, is_parent)
      file_path = "#{dir}/#{name}_test.md"
      :ok = CodeMySpec.Environments.write_file(env, file_path, content)
      [%{component: component, file_path: file_path, prompt_type: :test, phase: 4}]
    else
      []
    end
  end

  defp maybe_generate_code_prompt({scope, session, component, env, dir, name}, is_parent, needs) do
    if :code in needs do
      {:ok, content} = code_command(scope, session, is_parent)
      file_path = "#{dir}/#{name}_code.md"
      :ok = CodeMySpec.Environments.write_file(env, file_path, content)
      [%{component: component, file_path: file_path, prompt_type: :code, phase: 4}]
    else
      []
    end
  end

  defp test_command(scope, session, true), do: LiveViewTest.command(scope, session)
  defp test_command(scope, session, false), do: ComponentTest.command(scope, session)

  defp code_command(scope, session, true), do: LiveViewCode.command(scope, session)
  defp code_command(scope, session, false), do: ComponentCode.command(scope, session)

  defp safe_filename(module_name) do
    module_name
    |> String.replace(".", "_")
    |> String.downcase()
  end

  # Private functions - Prompt building

  defp build_orchestration_prompt(
         _liveview_component,
         %{complete: true},
         _prompt_files,
         _status_dir
       ) do
    {:ok,
     """
     LiveView lifecycle is complete. All phases have passed:
     - LiveView specification
     - Component specifications
     - Design review
     - Implementation

     No further action required.
     """}
  end

  defp build_orchestration_prompt(liveview_component, phase_status, prompt_files, _status_dir) do
    current_phase = determine_current_phase(phase_status)
    phase_text = format_phase_instructions(current_phase, prompt_files)

    {:ok,
     """
     # LiveView Lifecycle: #{liveview_component.name}

     You are orchestrating the full development lifecycle for this LiveView.

     ## Lifecycle Phases

     1. **LiveView Spec** - Define the LiveView architecture, route, interactions
     2. **Component Specs** - Design each child component
     3. **Design Review** - Validate architecture before implementation
     4. **Implementation** - Tests + code in dependency order (children first, parent last)

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
      match?({:missing, _}, phase_status[:liveview_spec]) -> :liveview_spec
      match?({:missing, _}, phase_status[:component_specs]) -> :component_specs
      match?({:missing, _}, phase_status[:design_review]) -> :design_review
      match?({:missing, _}, phase_status[:implementation]) -> :implementation
      true -> :complete
    end
  end

  defp format_phase_name(:liveview_spec), do: "LiveView Specification"
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
      - **Children** first (child components have no cross-dependencies)
      - **Parent LiveView** last (composes and coordinates all children)

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

  defp phase_to_number(:liveview_spec), do: 1
  defp phase_to_number(:component_specs), do: 2
  defp phase_to_number(:component_spec), do: 2
  defp phase_to_number(:design_review), do: 3
  defp phase_to_number(:implementation), do: 4
  defp phase_to_number(_), do: 0

  # Private functions - Cleanup

  defp cleanup_completed_phases(phase_status, status_dir, working_dir) do
    completed_suffixes =
      if phase_status[:complete] == true do
        [:liveview_spec, :component_specs, :design_review, :implementation]
        |> Enum.flat_map(&phase_to_suffixes/1)
      else
        [:liveview_spec, :component_specs, :design_review, :implementation]
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

  defp phase_to_suffixes(:liveview_spec), do: ["_live_view_spec.md"]
  defp phase_to_suffixes(:component_specs), do: ["_component_spec.md"]
  defp phase_to_suffixes(:design_review), do: ["_design_review.md"]
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

  defp build_feedback(liveview_component, incomplete_phases, status_dir) do
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
    LiveView "#{liveview_component.name}" (#{liveview_component.module_name}) has incomplete phases:
    #{phases_text}

    Read your updated instructions at `#{status_dir}/develop_live_view.md` and complete the current phase.
    When you finish the phase, stop the session again so validation can advance you to the next phase.
    """
  end
end
