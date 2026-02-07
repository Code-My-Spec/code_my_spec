defmodule CodeMySpec.AgentTasks.ComponentSpec do
  @moduledoc """
  Consolidated component spec session for Claude Code slash commands.

  Two main functions:
  - `command/3` - Called by slash command to generate the prompt for Claude
  - `evaluate/3` - Called by stop hook to validate output and provide feedback
  """

  alias CodeMySpec.{Rules, Utils, Environments, Documents}
  alias CodeMySpec.Documents.DocumentSpecProjector
  alias CodeMySpec.Components.Component

  @doc """
  Generate the command/prompt for Claude to create a component spec.

  Called by the slash command to build the initial prompt with:
  - Design rules
  - Document specifications
  - Project context
  - Component details

  Returns {:ok, prompt_text}
  """
  def command(scope, session, _opts \\ []) do
    %{component: component} = session

    with {:ok, rules} <- get_design_rules(scope, component) do
      build_spec_prompt(scope, session, rules)
    end
  end

  @doc """
  Evaluate Claude's output and provide feedback if needed.

  Called by the stop hook after Claude generates the spec. This:
  1. Reads the generated spec file
  2. Validates it against the document schema
  3. Returns success if valid
  4. Returns validation errors if invalid (for Claude to fix)

  Returns:
  - {:ok, :valid} if the spec passes validation
  - {:ok, :invalid, errors} if the spec needs revision
  - {:error, reason} if something went wrong
  """
  def evaluate(scope, session, _opts \\ []) do
    with {:ok, spec_content} <- read_spec_file(scope, session),
         {:ok, _document} <- validate_document(spec_content, session.component) do
      {:ok, :valid}
    else
      {:error, validation_errors} when is_binary(validation_errors) ->
        # Spec exists but is invalid - return errors for Claude to fix
        {:ok, :invalid, build_revision_feedback(validation_errors)}
    end
  end

  # Private functions

  defp get_design_rules(_scope, component) do
    component_type = component.type

    Rules.find_matching_rules(component_type, "design")
    |> case do
      rules when is_list(rules) -> {:ok, rules}
    end
  end

  defp build_spec_prompt(scope, session, rules) do
    %{project: project, component: component} = session
    rules_text = Enum.map_join(rules, "\n\n", & &1.content)
    document_spec = DocumentSpecProjector.project_spec(component.type)
    %{spec_file: spec_file_path} = Utils.component_files(component, project)

    parent_component_clause =
      case Map.get(component, :parent_component, nil) do
        %Component{} = parent_component ->
          %{spec_file: parent_spec_file_path} =
            Utils.component_files(parent_component, project)

          "Parent Context Design File: #{parent_spec_file_path}"

        _ ->
          ""
      end

    environment = scope.environment

    %{code_file: code_file, test_file: test_file} =
      Utils.component_files(component, project)

    existing_implementation_clause =
      if Environments.file_exists?(environment, code_file) do
        "Existing Implementation: #{code_file}."
      else
        "The implementation doesn't exist yet."
      end

    existing_test_clause =
      if Environments.file_exists?(environment, test_file) do
        "Existing tests: #{test_file}"
      else
        "The tests don't exist yet."
      end

    prompt =
      """
      Generate a Phoenix component spec for the following.
      Project: #{project.name}
      Project Description: #{project.description}
      Component Name: #{component.name}
      Component Description: #{component.description || "No description provided"}
      Type: #{component.type}
      #{parent_component_clause}
      #{existing_implementation_clause}
      #{existing_test_clause}

      Design Rules:
      #{rules_text}

      Document Specifications:
      #{document_spec}

      Write the document to #{spec_file_path}.
      """

    {:ok, prompt}
  end

  defp read_spec_file(scope, session) do
    %{spec_file: path} = Utils.component_files(session.component, session.project)

    environment = scope.environment

    case Environments.read_file(environment, path) do
      {:ok, content} ->
        if String.trim(content) == "" do
          {:error, "Spec file is empty"}
        else
          {:ok, content}
        end

      {:error, :enoent} ->
        {:error, "Spec file not found at #{path}"}

      {:error, error} ->
        {:error, "Failed to read file #{path}: #{inspect(error)}"}
    end
  end

  defp validate_document(spec_content, component) do
    Documents.create_dynamic_document(spec_content, component.type)
  end

  defp build_revision_feedback(validation_errors) do
    """
    The component design failed validation:

    Validation errors:
    #{validation_errors}

    Please revise the component design to address these validation errors while maintaining the overall structure and intent of the design.
    """
  end
end
