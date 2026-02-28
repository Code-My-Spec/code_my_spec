defmodule CodeMySpec.AgentTasks.RefactorModule do
  @moduledoc """
  Agent task for guiding interactive refactoring sessions with Claude Code.

  Routes to component or context-specific refactoring based on the component type.
  Provides an open-ended, conversational workflow where the agent:
  1. Reviews existing spec, tests, and implementation
  2. Asks the user what they want to refactor
  3. Has a conversation with the user to understand requirements
  4. Modifies the spec first, then tests, then implementation
  5. Relies on standard validate_edits hook for validation
  """

  alias CodeMySpec.{Rules, Utils, Components, Environments}

  @doc """
  Generate the command/prompt for Claude to start the refactoring session.

  Routes to component or context-specific refactoring based on component type.
  """
  def command(scope, session, _opts \\ []) do
    %{component: component} = session

    case component.type do
      "context" -> command_for_context(scope, session)
      _ -> command_for_component(scope, session)
    end
  end

  @doc """
  Evaluate the refactoring session after completion.

  Always returns {:ok, :valid} since we rely on the standard validate_edits hook.
  """
  def evaluate(_scope, _session, _opts \\ []) do
    {:ok, :valid}
  end

  # Private functions

  defp command_for_component(scope, session) do
    %{component: component, project: project} = session

    environment = scope.environment

    %{spec_file: spec_file, code_file: code_file, test_file: test_file} =
      Utils.component_files(component, project)

    # Read existing files
    spec_content = read_file_or_note(environment, spec_file)
    code_content = read_file_or_note(environment, code_file)
    test_content = read_file_or_note(environment, test_file)

    rules = Rules.find_matching_rules(component.type, "design", scope.environment.cwd)
    rules_text = Enum.map_join(rules, "\n\n", & &1.content)

    prompt = """
    Your task is to help refactor a Phoenix component in an interactive, conversational way.

    # Project

    Project: #{project.name}
    Project Description: #{project.description}

    # Component

    Component Name: #{component.name}
    Component Description: #{component.description || "No description provided"}
    Type: #{component.type}

    # Current Files

    ## Spec File: #{spec_file}
    #{spec_content}

    ## Implementation: #{code_file}
    #{code_content}

    ## Tests: #{test_file}
    #{test_content}

    # Design Rules
    #{rules_text}

    # Your Approach

    1. **Review the code**: Take a moment to understand the current implementation, tests, and spec
    2. **Ask the user**: Find out what they want to refactor and why
    3. **Have a conversation**: Discuss options, trade-offs, and clarify requirements
    4. **Make changes in order**:
       - First update the spec to reflect the new design
       - Then update the tests to match the new spec
       - Finally update the implementation to pass the tests

    Remember: This is a collaborative refactoring session. Feel free to ask questions, suggest alternatives, and iterate with the user.

    Start by asking the user what they'd like to refactor and what their goals are.
    """

    {:ok, prompt}
  end

  defp command_for_context(scope, session) do
    %{component: context, project: project} = session

    environment = scope.environment

    %{spec_file: context_spec_file} = Utils.component_files(context, project)

    # Read context spec
    context_spec_content = read_file_or_note(environment, context_spec_file)

    # Get all child components
    child_components = Components.list_child_components(scope, context.id)

    child_components_overview =
      case child_components do
        [] ->
          "No child components found."

        children ->
          Enum.map_join(children, "\n", fn child ->
            files = Utils.component_files(child, project)

            """
            - #{child.name} (#{child.type})
              Description: #{child.description || "No description"}
              Spec: #{files.spec_file}
              Implementation: #{files.code_file}
              Tests: #{files.test_file}
            """
          end)
      end

    rules = Rules.find_matching_rules("context", "design", scope.environment.cwd)
    rules_text = Enum.map_join(rules, "\n\n", & &1.content)

    prompt = """
    Your task is to help refactor a Phoenix bounded context in an interactive, conversational way.

    # Project

    Project: #{project.name}
    Project Description: #{project.description}

    # Context

    Context Name: #{context.name}
    Context Description: #{context.description || "No description provided"}

    ## Context Spec: #{context_spec_file}
    #{context_spec_content}

    # Child Components

    #{child_components_overview}

    # Design Rules
    #{rules_text}

    # Your Approach

    1. **Review the context**: Understand the current context design and all child components
    2. **Ask the user**: Find out what they want to refactor and why
    3. **Have a conversation**: Discuss options, trade-offs, scope, and clarify requirements
    4. **Make changes in order**:
       - Update affected specs first (context and/or child components)
       - Then update tests
       - Finally update implementations

    Remember: This is a collaborative refactoring session for a bounded context. Consider how changes might ripple through child components. Feel free to ask questions, suggest alternatives, and iterate with the user.

    Start by asking the user what they'd like to refactor and what their goals are.
    """

    {:ok, prompt}
  end

  defp read_file_or_note(environment, path) do
    case Environments.read_file(environment, path) do
      {:ok, content} -> content
      {:error, :enoent} -> "(File does not exist yet)"
      {:error, _} -> "(Could not read file)"
    end
  end
end
