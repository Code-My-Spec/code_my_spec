defmodule CodeMySpec.AgentTasks.ComponentTest do
  @moduledoc """
  Consolidated component test session for Claude Code slash commands.

  Two main functions:
  - `command/3` - Called by slash command to generate the test writing prompt
  - `evaluate/3` - Called by stop hook to check test requirements are satisfied
  """

  alias CodeMySpec.AgentTasks.ProblemFeedback
  alias CodeMySpec.Components
  alias CodeMySpec.Components.ComponentRepository
  alias CodeMySpec.Problems
  alias CodeMySpec.Requirements
  alias CodeMySpec.Rules
  alias CodeMySpec.Utils

  def analyzers, do: []

  # While the agent is writing tests, exunit failures are expected (the
  # implementation may not exist yet) — running `mix test --stale` would
  # block the stop with TDD-mode failures. Opt out of exunit_stale here
  # so the role-derived `[:credo, :exunit_stale]` for any in-scope impl
  # file (which can land in changed_files when sync timing collides
  # with the second-truncated `started_at`) doesn't trigger it.
  def excluded_analyzers, do: [:exunit_stale]

  @doc """
  Generate the command/prompt for Claude to write component tests.

  Called by the slash command to build the prompt with:
  - Spec file location
  - Test rules
  - TDD context (implementation exists or not)
  - Prior validator/analyzer diagnostics on a re-fire

  Returns {:ok, prompt_text}
  """
  def command(scope, task) do
    component = Components.get_component!(scope, task.component_id)
    project = scope.active_project

    with {:ok, test_rules} <- get_test_rules(scope, component) do
      diagnostics = previous_validation_diagnostics(scope, component, project)
      {:ok, prompt} = build_test_prompt(scope, component, project, test_rules, diagnostics)
      {:ok, prompt}
    end
  end

  @doc """
  Evaluate whether the test file was written correctly.

  Passes when the test artifact requirements are met. Persisted problems on
  the test file never hold it (see `ProblemFeedback.combine/2`); they are
  context in the feedback when a requirement is unmet.

  Returns:
  - {:ok, :valid} if the test artifact requirements are met
  - {:ok, :invalid, feedback} if one is not
  """
  def evaluate(scope, task) do
    component = Components.get_component!(scope, task.component_id)
    project = scope.active_project
    component = ComponentRepository.get_component(scope, component.id)

    req_feedback = CodeMySpec.AgentTasks.artifact_feedback(scope, component, :test)

    problem_feedback = ProblemFeedback.for_test_task(scope, component, project)
    ProblemFeedback.combine(req_feedback, problem_feedback)
  end

  def dispatch(_node) do
    "Write the test file for a component based on its spec's test assertions. " <>
      "Use when the component spec is valid and no test file exists yet, or " <>
      "the test file needs revision. Sub-agent: spawn @test-writer."
  end

  # Private functions - command

  defp get_test_rules(scope, component) do
    component_type = component.type

    Rules.find_matching_rules(component_type, "test", CodeMySpec.AgentTasks.environment(scope))
    |> case do
      rules when is_list(rules) -> {:ok, rules}
    end
  end

  defp build_test_prompt(scope, component, project, test_rules, diagnostics) do
    test_rules_text = Enum.map_join(test_rules, "\n\n", & &1.content)

    %{test_file: test_file_path} = Utils.component_files(component, project)

    implementation_exists = implementation_exists?(scope, component)

    tdd_section =
      if implementation_exists do
        """
        The component implementation already exists.
        Write tests that validate the existing implementation against its design.
        """
      else
        """
        The component doesn't exist yet.
        You are to write the tests before we implement the module, TDD style.
        """
      end

    prompt =
      """
      Generate tests and fixtures for the following Phoenix component.
      #{tdd_section}
      #{diagnostics}
      Tests should be grouped by describe blocks that match the function signature EXACTLY.

      describe "get_test_assertions/1" do
        test "extracts test names from test blocks", %{tmp_dir: tmp_dir} do
          ...test code
        end
      end

      Project: #{project.name}
      Project Description: #{project.description}
      Component Name: #{component.name}
      Component Type: #{component.type}

      The component, its parent context and what it depends on are records: read
      the component with `get_component` (module_name `#{component.module_name}`), and
      the wider picture with `show_namespace_hierarchy`. The linked story's BDD spex
      (under `test/spex/<story_number>_*/`) are the contract for its behaviour.

      Test Rules:
      #{test_rules_text}

      Write the test file to #{test_file_path}.

      Focus on:
      - Reading the component and its parent context to understand the architecture
      - Creating reusable fixture functions for test data
      - Testing all public API functions
      - Testing edge cases and error conditions
      - Testing with valid and invalid data
      - Following test and fixture organization patterns from the rules
      """

    {:ok, prompt}
  end

  defp implementation_exists?(scope, component) do
    code_reqs = Requirements.check_artifact_requirements(scope, component, :code)
    Enum.any?(code_reqs, &(&1.name == "implementation_file" && &1.satisfied))
  end

  # Surfaces prior validator + analyzer diagnostics on a re-fire so the
  # agent doesn't repeat the same mistake. Skipped on the first attempt
  # (test_file missing) — there's nothing to diagnose yet.
  defp previous_validation_diagnostics(scope, component, project) do
    component = ComponentRepository.get_component(scope, component.id)
    req_section = CodeMySpec.AgentTasks.artifact_feedback(scope, component, :test)

    problem_section = ProblemFeedback.for_test_task(scope, component, project)

    body =
      [req_section, problem_section]
      |> Enum.reject(&is_nil/1)
      |> Enum.join("\n\n")

    case body do
      "" ->
        ""

      content ->
        """

        # Previous validation diagnostics

        Re-read the test file at the path above and revise it to address each
        diagnostic below before re-writing.

        #{Problems.truncate_to_cap(content)}
        """
    end
  end
end
