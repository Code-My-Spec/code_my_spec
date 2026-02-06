defmodule CodeMySpec.AgentTasks.ContextComponentSpecs do
  @moduledoc """
  Agent task for designing a context and all its child components.

  Two main functions:
  - `command/3` - Checks spec requirements for context + children, generates prompt files, returns orchestration prompt
  - `evaluate/3` - Re-checks all requirements, returns feedback if any unsatisfied
  """

  alias CodeMySpec.{Requirements, Environments}
  alias CodeMySpec.Components.ComponentRepository
  alias CodeMySpec.AgentTasks.{ComponentSpec, ContextSpec}

  defp prompt_dir(external_id),
    do: ".code_my_spec/internal/sessions/#{external_id}/subagent_prompts"

  @doc """
  Generate the orchestration prompt for designing child components.

  1. Fetches all child components of the context
  2. Checks spec requirements for each child
  3. For children needing specs, generates prompt files using ComponentSpec.command/3
  4. Returns prompt instructing Claude to invoke @"CodeMySpec:spec-writer (agent)" for each component

  Returns {:ok, prompt_text}
  """
  def command(scope, session, _opts \\ []) do
    %{component: context_component, external_id: external_id} = session
    # Ensure requirements are preloaded on context component
    IO.inspect("starting")
    context_component = ComponentRepository.get_component(scope, context_component.id)

    with {:ok, context_prompt_file} <-
           maybe_generate_context_prompt(scope, session, context_component, external_id),
         {:ok, children} <- get_child_components(scope, context_component),
         {:ok, children_needing_specs} <- filter_children_needing_specs(scope, children, session),
         {:ok, child_prompt_files} <-
           generate_child_prompt_files(scope, session, children_needing_specs, external_id) do
      build_orchestration_prompt(
        context_component,
        context_prompt_file,
        child_prompt_files,
        external_id
      )
    end
  end

  @doc """
  Evaluate whether all child components have valid specs.

  Returns:
  - {:ok, :valid} if all children have satisfied spec requirements
  - {:ok, :invalid, feedback} if some children still need specs
  - {:error, reason} if evaluation failed
  """
  def evaluate(scope, session, _opts \\ []) do
    %{component: context_component, external_id: external_id} = session
    # Ensure requirements are preloaded on context component
    context_component = ComponentRepository.get_component(scope, context_component.id)

    with {:ok, context_unsatisfied} <-
           check_context_spec_status(scope, context_component, session),
         {:ok, children} <- get_child_components(scope, context_component),
         {:ok, satisfied, unsatisfied} <- check_children_spec_status(scope, children, session),
         :ok <- cleanup_prompt_files(satisfied, external_id),
         :ok <- maybe_cleanup_context_prompt(context_component, context_unsatisfied, external_id) do
      all_unsatisfied = context_unsatisfied ++ unsatisfied

      case all_unsatisfied do
        [] ->
          cleanup_prompt_directory(external_id)
          {:ok, :valid}

        components_still_needing_specs ->
          feedback = build_feedback(components_still_needing_specs, external_id)
          {:ok, :invalid, feedback}
      end
    end
  end

  # Private functions

  defp get_child_components(scope, context_component) do
    # Use recursive descent to get all children, grandchildren, etc.
    # This handles nested structures like analyzers/ subdirectories
    children = ComponentRepository.list_all_descendants(scope, context_component.id)
    {:ok, children}
  end

  defp maybe_generate_context_prompt(scope, session, context_component, external_id) do
    # Filter persisted requirements to spec-related ones
    results =
      Requirements.check_requirements(
        scope,
        context_component,
        context_component.requirements,
        include: ["spec_file", "spec_valid"]
      )

    context_needs_spec = Enum.any?(results, fn result -> not result.satisfied end)

    if context_needs_spec do
      {:ok, environment} =
        Environments.create(session.environment_type, working_dir: session[:working_dir])

      # Use ContextSpec.command/3 to generate the prompt content
      {:ok, prompt_content} = ContextSpec.command(scope, session)

      # Write prompt file (write_file will create parent directories)
      safe_name = safe_filename(context_component.module_name)
      relative_path = "#{prompt_dir(external_id)}/#{safe_name}_context.md"
      :ok = Environments.write_file(environment, relative_path, prompt_content)

      # Store absolute path for orchestration prompt (agents need full path)
      absolute_path = Path.join(session[:working_dir] || ".", relative_path)
      {:ok, %{component: context_component, file_path: absolute_path, type: :context}}
    else
      {:ok, nil}
    end
  end

  defp filter_children_needing_specs(scope, children, _session) do
    children_needing_specs =
      Enum.filter(children, fn child ->
        # Filter persisted requirements to spec-related ones
        results =
          Requirements.check_requirements(
            scope,
            child,
            child.requirements,
            include: ["spec_file", "spec_valid"]
          )

        # Child needs spec if any spec requirement is unsatisfied
        Enum.any?(results, fn result -> not result.satisfied end)
      end)

    {:ok, children_needing_specs}
  end

  defp generate_child_prompt_files(scope, session, children_needing_specs, external_id) do
    %{project: project} = session

    {:ok, environment} =
      Environments.create(session.environment_type, working_dir: session[:working_dir])

    prompt_files =
      Enum.map(children_needing_specs, fn child ->
        # Build a mini-session for the child component
        child_session = %{
          external_id: external_id,
          component: child,
          project: project,
          environment_type: session.environment_type,
          working_dir: session[:working_dir]
        }

        # Use ComponentSpec.command/3 to generate the prompt content
        {:ok, prompt_content} = ComponentSpec.command(scope, child_session)

        # Write prompt file
        safe_name = safe_filename(child.module_name)
        relative_path = "#{prompt_dir(external_id)}/#{safe_name}.md"
        :ok = Environments.write_file(environment, relative_path, prompt_content)

        # Store absolute path for orchestration prompt (agents need full path)
        absolute_path = Path.join(session[:working_dir] || ".", relative_path)

        %{
          component: child,
          file_path: absolute_path,
          type: :child
        }
      end)

    {:ok, prompt_files}
  end

  defp safe_filename(module_name) do
    module_name
    |> String.replace(".", "_")
    |> String.downcase()
  end

  defp build_orchestration_prompt(context_component, nil, [], _external_id) do
    # No context or children need specs
    {:ok,
     """
     Context #{context_component.name} and all its child components already have valid specifications.
     No further action required.
     """}
  end

  defp build_orchestration_prompt(
         context_component,
         context_prompt_file,
         child_prompt_files,
         _external_id
       ) do
    all_prompt_files =
      case context_prompt_file do
        nil -> child_prompt_files
        file -> [file | child_prompt_files]
      end

    task_instructions =
      Enum.map_join(all_prompt_files, "\n\n", fn %{component: comp, file_path: path} ->
        """
        ## Task: Design #{comp.name}

        Read the prompt file at #{path} and follow the instructions to create the specification. Write the spec file to the location specified in the prompt.
        """
      end)

    context_note = if context_prompt_file, do: " (including the context itself)", else: ""
    total_count = length(all_prompt_files)

    {:ok,
     """
     # Context Components Design: #{context_component.name}

     You need to design #{total_count} specification(s) for this context#{context_note}.

     ## Instructions

     For each component below, invoke the @"CodeMySpec:spec-writer (agent)" subagent to:
     1. Read the prompt file for that component
     2. Follow the instructions in that prompt to create the specification
     3. Write the spec file to the specified location

     You can invoke multiple subagents in parallel for efficiency.

     #{task_instructions}

     ## Completion

     Once all subagents have completed their tasks, verify that all specifications
     have been created successfully. The stop hook will validate the results.
     """}
  end

  defp check_context_spec_status(scope, context_component, _session) do
    # Filter persisted requirements to spec-related ones
    results =
      Requirements.check_requirements(
        scope,
        context_component,
        context_component.requirements,
        include: ["spec_file", "spec_valid"]
      )

    if Enum.all?(results, & &1.satisfied) do
      {:ok, []}
    else
      unsatisfied_reqs =
        results
        |> Enum.reject(& &1.satisfied)
        |> Enum.map(&extract_requirement_info/1)

      {:ok,
       [
         %{
           component: context_component,
           unsatisfied_requirements: unsatisfied_reqs,
           type: :context
         }
       ]}
    end
  end

  defp check_children_spec_status(scope, children, _session) do
    {satisfied, unsatisfied} =
      Enum.split_with(children, fn child ->
        # Filter persisted requirements to spec-related ones
        results =
          Requirements.check_requirements(
            scope,
            child,
            child.requirements,
            include: ["spec_file", "spec_valid"]
          )

        Enum.all?(results, & &1.satisfied)
      end)

    unsatisfied_with_details =
      Enum.map(unsatisfied, fn child ->
        results =
          Requirements.check_requirements(
            scope,
            child,
            child.requirements,
            include: ["spec_file", "spec_valid"]
          )

        unsatisfied_reqs =
          results
          |> Enum.reject(& &1.satisfied)
          |> Enum.map(&extract_requirement_info/1)

        %{component: child, unsatisfied_requirements: unsatisfied_reqs, type: :child}
      end)

    {:ok, satisfied, unsatisfied_with_details}
  end

  defp maybe_cleanup_context_prompt(context_component, [], external_id) do
    # Context is satisfied, clean up its prompt file if it exists
    file_path =
      "#{prompt_dir(external_id)}/#{safe_filename(context_component.module_name)}_context.md"

    if File.exists?(file_path) do
      File.rm(file_path)
    end

    :ok
  end

  defp maybe_cleanup_context_prompt(_context_component, _unsatisfied, _external_id), do: :ok

  defp cleanup_prompt_files(satisfied_children, external_id) do
    Enum.each(satisfied_children, fn child ->
      file_path = "#{prompt_dir(external_id)}/#{safe_filename(child.module_name)}.md"

      if File.exists?(file_path) do
        File.rm(file_path)
      end
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
      Enum.map_join(unsatisfied_components, "\n", fn %{
                                                       component: comp,
                                                       unsatisfied_requirements: reqs,
                                                       type: type
                                                     } ->
        type_label = if type == :context, do: "context", else: "component"
        req_messages = Enum.map_join(reqs, "; ", &format_requirement_message/1)
        "- #{comp.name} (#{comp.module_name}) [#{type_label}]: #{req_messages}"
      end)

    """
    The following components still need their specifications completed:

    #{components_list}

    Please ensure your `@"CodeMySpec:spec-writer (agent)"` subagents have completed creating the specification files for these components.
    The subagents should:
    1. Read their assigned prompt file from #{prompt_dir(external_id)}/
    2. Create valid specification documents following the Document Specifications
    3. Write the spec files to the correct locations

    Re-invoke `@"CodeMySpec:spec-writer (agent)"` for any components that failed or haven't completed.
    """
  end

  # Extracts requirement name and error details from a requirement check result
  defp extract_requirement_info(%{name: name, details: details}) when is_map(details) do
    error_message = extract_error_message(details)
    %{name: name, error: error_message}
  end

  defp extract_requirement_info(%{name: name}) do
    %{name: name, error: nil}
  end

  # Extracts a user-friendly error message from the details map
  defp extract_error_message(%{reason: reason, error: error}) when is_binary(error) do
    "#{reason}: #{error}"
  end

  defp extract_error_message(%{reason: reason}) when is_binary(reason) do
    reason
  end

  defp extract_error_message(%{error: error}) when is_binary(error) do
    error
  end

  defp extract_error_message(_details), do: nil

  # Formats a requirement info map into a user-friendly message
  defp format_requirement_message(%{name: name, error: nil}) do
    "missing #{name}"
  end

  defp format_requirement_message(%{name: _name, error: error}) do
    error
  end
end
