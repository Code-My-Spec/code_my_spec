defmodule CodeMySpec.AgentTasks.DevelopController do
  @moduledoc """
  Orchestrates the full lifecycle of a Phoenix controller from specification through implementation.

  A simplified 2-phase lifecycle (no children, no design review):

  1. **Controller Spec** — Define controller actions, routes, and JSON view structure
  2. **Implementation** — Tests + code (controller + JSON view in a single pass)

  The controller produces two implementation files: `*_controller.ex` and `*_json.ex`.
  A single sub-agent invocation handles both files together since the spec describes both.

  Writes prompt files to `docs/status/{root}/{controller}/` following the same
  conventions as DevelopContext and DevelopLiveView.
  """

  require Logger

  alias CodeMySpec.Components.ComponentRepository
  alias CodeMySpec.Utils.Paths

  alias CodeMySpec.AgentTasks.{
    ComponentCode,
    ComponentSpec,
    ComponentTest
  }

  @status_dir CodeMySpec.Paths.status_dir()

  defp controller_status_dir(controller_component) do
    parts =
      controller_component.module_name
      |> String.split(".")
      |> Enum.map(&Macro.underscore/1)

    {dir_parts, [dirname]} = Enum.split(parts, -1)
    Path.join([@status_dir | dir_parts] ++ [dirname])
  end

  @doc """
  Generate prompt files and orchestration instructions for the controller lifecycle.

  Returns {:ok, prompt_text}
  """
  def command(scope, session, _opts \\ []) do
    %{component: controller_component} = session
    controller_component = ComponentRepository.get_component(scope, controller_component.id)

    # Ensure companion JSON view has a stub spec so sync discovers it with type "json"
    ensure_json_stub_spec(scope, controller_component)

    status_dir = controller_status_dir(controller_component)

    with {:ok, phase_status} <-
           check_lifecycle_phases(scope, session, controller_component),
         {:ok, prompt_files} <-
           generate_phase_prompts(
             scope,
             session,
             controller_component,
             phase_status,
             status_dir
           ) do
      {:ok, orchestration_content} =
        build_orchestration_prompt(
          controller_component,
          session.project,
          phase_status,
          prompt_files,
          status_dir
        )

      orchestration_path = "#{status_dir}/develop_controller.md"

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
  Validate all lifecycle phases are complete for the controller.

  Returns:
  - {:ok, :valid} if all phases pass
  - {:ok, :invalid, feedback} if some phases are incomplete
  """
  def evaluate(scope, session, _opts \\ []) do
    %{component: controller_component} = session

    Logger.info(
      "[DevelopController] evaluate called for controller: #{controller_component.name} (#{controller_component.module_name})"
    )

    controller_component = ComponentRepository.get_component(scope, controller_component.id)
    status_dir = controller_status_dir(controller_component)
    working_dir = scope.environment && scope.environment.cwd

    with {:ok, phase_status} <-
           check_lifecycle_phases(scope, session, controller_component),
         :ok <- cleanup_completed_phases(phase_status, status_dir, working_dir) do
      handle_phase_result(phase_status, scope, session, controller_component, status_dir, working_dir)
    end
  end

  defp handle_phase_result(%{complete: true}, _scope, _session, _component, status_dir, working_dir) do
    Logger.info("[DevelopController] All phases complete")
    cleanup_status_directory(status_dir, working_dir)
    {:ok, :valid}
  end

  defp handle_phase_result(%{incomplete_phases: incomplete} = phase_status, scope, session, controller_component, status_dir, _working_dir) do
    phase_names =
      Enum.map_join(incomplete, ", ", fn {phase, _} -> Atom.to_string(phase) end)

    Logger.info("[DevelopController] Incomplete phases: #{phase_names}")

    {:ok, prompt_files} =
      generate_phase_prompts(scope, session, controller_component, phase_status, status_dir)

    {:ok, orchestration_content} =
      build_orchestration_prompt(
        controller_component,
        session.project,
        phase_status,
        prompt_files,
        status_dir
      )

    orchestration_path = "#{status_dir}/develop_controller.md"

    CodeMySpec.Environments.write_file(
      scope.environment,
      orchestration_path,
      orchestration_content
    )

    feedback = build_feedback(controller_component, incomplete, status_dir)
    {:ok, :invalid, feedback}
  end

  # ============================================================================
  # Phase Checking
  # ============================================================================

  defp check_lifecycle_phases(scope, session, controller_component) do
    controller_spec_status = check_controller_spec(scope, session, controller_component)
    implementation_status = check_implementation(scope, controller_component)

    incomplete_phases =
      []
      |> maybe_add_phase(:controller_spec, controller_spec_status)
      |> maybe_add_phase(:implementation, implementation_status)

    status =
      if Enum.empty?(incomplete_phases) do
        %{complete: true}
      else
        %{
          complete: false,
          incomplete_phases: incomplete_phases,
          controller_spec: controller_spec_status,
          implementation: implementation_status
        }
      end

    {:ok, status}
  end

  defp maybe_add_phase(phases, _name, :complete), do: phases
  defp maybe_add_phase(phases, name, status), do: [{name, status} | phases]

  defp check_controller_spec(scope, session, controller_component) do
    child_session = %{component: controller_component, project: session.project}

    case ComponentSpec.evaluate(scope, child_session) do
      {:ok, :valid} -> :complete
      _ -> {:missing, [controller_component]}
    end
  end

  defp check_implementation(scope, controller_component) do
    requirements = controller_component.requirements || []

    test_results =
      CodeMySpec.Requirements.check_requirements(
        scope,
        controller_component,
        requirements,
        artifact_types: [:tests]
      )

    code_results =
      CodeMySpec.Requirements.check_requirements(
        scope,
        controller_component,
        requirements,
        artifact_types: [:code]
      )

    needs_tests = Enum.any?(test_results, fn r -> not r.satisfied end)
    needs_code = Enum.any?(code_results, fn r -> not r.satisfied end)

    needs =
      if(needs_tests, do: [:test], else: []) ++
        if(needs_code, do: [:code], else: [])

    if needs == [] do
      :complete
    else
      {:missing, [{controller_component, needs}]}
    end
  end

  # ============================================================================
  # Prompt Generation
  # ============================================================================

  defp generate_phase_prompts(scope, session, controller_component, phase_status, status_dir) do
    environment = scope.environment

    ctx = %{
      scope: scope,
      session: session,
      controller_component: controller_component,
      environment: environment,
      status_dir: status_dir
    }

    prompt_files =
      []
      |> maybe_add_controller_spec_prompts(phase_status, ctx)
      |> maybe_add_implementation_prompts(phase_status, ctx)

    {:ok, prompt_files}
  end

  defp maybe_add_controller_spec_prompts(
         acc,
         %{controller_spec: {:missing, _}},
         ctx
       ) do
    acc ++ generate_controller_spec_prompt(ctx)
  end

  defp maybe_add_controller_spec_prompts(acc, _status, _ctx), do: acc

  defp maybe_add_implementation_prompts(
         acc,
         %{controller_spec: :complete, implementation: {:missing, components_with_needs}},
         ctx
       ) do
    acc ++ generate_implementation_prompts(ctx, components_with_needs)
  end

  defp maybe_add_implementation_prompts(acc, _status, _ctx), do: acc

  defp generate_controller_spec_prompt(ctx) do
    child_session = %{component: ctx.controller_component, project: ctx.session.project}
    {:ok, prompt_content} = ComponentSpec.command(ctx.scope, child_session)

    safe_name = safe_filename(ctx.controller_component.module_name)
    file_path = "#{ctx.status_dir}/#{safe_name}_controller_spec.md"
    :ok = CodeMySpec.Environments.write_file(ctx.environment, file_path, prompt_content)

    [
      %{
        component: ctx.controller_component,
        file_path: file_path,
        prompt_type: :controller_spec,
        phase: 1
      }
    ]
  end

  defp generate_implementation_prompts(ctx, components_with_needs) do
    Enum.flat_map(components_with_needs, fn {component, needs} ->
      child_session = %{component: component, project: ctx.session.project}
      safe_name = safe_filename(component.module_name)

      test_prompts =
        if :test in needs do
          {:ok, content} = ComponentTest.command(ctx.scope, child_session)
          file_path = "#{ctx.status_dir}/#{safe_name}_test.md"
          :ok = CodeMySpec.Environments.write_file(ctx.environment, file_path, content)
          [%{component: component, file_path: file_path, prompt_type: :test, phase: 2}]
        else
          []
        end

      code_prompts =
        if :code in needs do
          {:ok, content} = ComponentCode.command(ctx.scope, child_session)
          file_path = "#{ctx.status_dir}/#{safe_name}_code.md"
          :ok = CodeMySpec.Environments.write_file(ctx.environment, file_path, content)
          [%{component: component, file_path: file_path, prompt_type: :code, phase: 2}]
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

  # ============================================================================
  # Orchestration Prompt
  # ============================================================================

  defp build_orchestration_prompt(
         _controller_component,
         _project,
         %{complete: true},
         _prompt_files,
         _status_dir
       ) do
    {:ok,
     """
     Controller lifecycle is complete. All phases have passed:
     - Controller specification
     - Implementation (controller + JSON view)

     No further action required.
     """}
  end

  defp build_orchestration_prompt(
         controller_component,
         project,
         phase_status,
         prompt_files,
         _status_dir
       ) do
    current_phase = determine_current_phase(phase_status)
    phase_text = format_phase_instructions(current_phase, prompt_files)

    files = CodeMySpec.Utils.component_files(controller_component, project)

    file_context =
      if Map.has_key?(files, :json_file) do
        """
        ## Controller Files

        - Controller: `#{files.code_file}`
        - JSON View: `#{files.json_file}`
        - Test: `#{files.test_file}`
        """
      else
        ""
      end

    {:ok,
     """
     # Controller Lifecycle: #{controller_component.name}

     You are orchestrating the full development lifecycle for this controller.

     ## Lifecycle Phases

     1. **Controller Spec** - Define controller actions, routes, and JSON view structure
     2. **Implementation** - Tests + code for both the controller and its JSON view

     #{file_context}

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

     **Note:** The implementation phase covers both the controller file and its
     companion JSON view file. Implement both in a single pass.
     """}
  end

  defp determine_current_phase(phase_status) do
    cond do
      match?({:missing, _}, phase_status[:controller_spec]) -> :controller_spec
      match?({:missing, _}, phase_status[:implementation]) -> :implementation
      true -> :complete
    end
  end

  defp format_phase_name(:controller_spec), do: "Controller Specification"
  defp format_phase_name(:implementation), do: "Implementation"
  defp format_phase_name(:complete), do: "Complete"

  defp format_phase_instructions(:implementation, prompt_files) do
    phase_files = Enum.filter(prompt_files, fn pf -> pf.phase == 2 end)

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

      component_tasks = Enum.map_join(by_component, "\n", &format_component_task/1)

      """
      Implement both the controller and its JSON view together.
      Write tests first, then implement code. Verify tests pass before stopping.

      #{component_tasks}

      For each task, invoke the appropriate subagent with the prompt file:
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

  defp phase_to_number(:controller_spec), do: 1
  defp phase_to_number(:implementation), do: 2
  defp phase_to_number(_), do: 0

  # ============================================================================
  # JSON Stub Spec
  # ============================================================================

  defp ensure_json_stub_spec(scope, controller_component) do
    module_name = controller_component.module_name

    case json_module_name(module_name) do
      nil ->
        :ok

      json_module ->
        json_module_path = Paths.module_to_path(json_module)
        spec_path = CodeMySpec.Paths.spec_file(json_module_path)

        case CodeMySpec.Environments.file_exists?(scope.environment, spec_path) do
          true ->
            :ok

          _ ->
            content = """
            # #{json_module}

            JSON view companion for #{module_name}.

            ## Type

            json
            """

            CodeMySpec.Environments.write_file(scope.environment, spec_path, content)
        end
    end
  end

  defp json_module_name(controller_module_name) do
    if String.ends_with?(controller_module_name, "Controller") do
      String.replace_suffix(controller_module_name, "Controller", "JSON")
    else
      nil
    end
  end

  # ============================================================================
  # Cleanup
  # ============================================================================

  defp cleanup_completed_phases(phase_status, status_dir, working_dir) do
    completed_suffixes =
      if phase_status[:complete] == true do
        [:controller_spec, :implementation]
        |> Enum.flat_map(&phase_to_suffixes/1)
      else
        [:controller_spec, :implementation]
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

  defp phase_to_suffixes(:controller_spec), do: ["_controller_spec.md"]
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

  defp build_feedback(controller_component, incomplete_phases, status_dir) do
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
    Controller "#{controller_component.name}" (#{controller_component.module_name}) has incomplete phases:
    #{phases_text}

    Read your updated instructions at `#{status_dir}/develop_controller.md` and complete the current phase.
    When you finish the phase, stop the session again so validation can advance you to the next phase.
    """
  end
end
