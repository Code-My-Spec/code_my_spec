defmodule CodeMySpec.AgentTasks.QaJourneyWallaby do
  @moduledoc """
  Generates Wallaby regression tests from passing QA journeys.

  Reads the journey plan and result, then builds a prompt instructing the agent
  to write Wallaby test files for passing journeys to `test/journeys/`.

  Two main functions:
  - `command/3` — Builds prompt to write Wallaby tests
  - `evaluate/3` — Checks at least one `*_test.exs` exists under `test/journeys/`
  """

  alias CodeMySpec.{Environments, Paths}

  @wallaby_dir Paths.qa_journey_wallaby_dir()
  @wallaby_glob Path.join(@wallaby_dir, "*_test.exs")

  @doc """
  Generate the prompt for the Wallaby test writing session.

  Reads the journey plan and result, then builds a prompt instructing the agent
  to write Wallaby tests for each passing journey.

  Returns `{:ok, prompt_text}`
  """
  def command(scope, _task) do
    env = scope.environment

    journey_plan = read_file(env, Paths.qa_journey_plan())
    journey_result = read_file(env, Paths.qa_journey_result())
    existing_tests = list_existing_tests(env)

    prompt = build_prompt(journey_plan, journey_result, existing_tests)

    {:ok, prompt}
  end

  @doc """
  Validate that at least one Wallaby journey test exists.

  Returns:
  - `{:ok, :valid}` if at least one `*_test.exs` exists under `test/journeys/`
  - `{:ok, :invalid, feedback}` if no tests found
  """
  def evaluate(scope, _task) do
    env = scope.environment

    case Environments.glob(env, @wallaby_glob) do
      files when is_list(files) and files != [] ->
        {:ok, :valid}

      _ ->
        {:ok, :invalid,
         "No journey tests found under `#{@wallaby_dir}/`. Write Wallaby tests and stop the session again."}
    end
  end

  # ============================================================================
  # Data Loading
  # ============================================================================

  defp read_file(env, path) do
    case Environments.read_file(env, path) do
      {:ok, content} when byte_size(content) > 0 -> content
      _ -> nil
    end
  end

  defp list_existing_tests(env) do
    case Environments.glob(env, @wallaby_glob) do
      files when is_list(files) and files != [] -> files
      _ -> []
    end
  end

  # ============================================================================
  # Prompt Building
  # ============================================================================

  defp build_prompt(journey_plan, journey_result, existing_tests) do
    sections =
      [
        build_header(),
        build_journey_plan_section(journey_plan),
        build_journey_result_section(journey_result),
        build_existing_tests_section(existing_tests),
        build_instructions()
      ]
      |> Enum.reject(&is_nil/1)

    Enum.join(sections, "\n\n")
  end

  defp build_header do
    """
    # QA Journey: Wallaby Test Generation

    You are converting passing QA journeys into permanent Wallaby regression tests.
    Each passing journey from the journey result becomes a Wallaby feature test
    that can be run as part of the project's test suite.\
    """
  end

  defp build_journey_plan_section(nil) do
    """
    ## Journey Plan

    No journey plan found. Cannot generate tests without a plan.\
    """
  end

  defp build_journey_plan_section(content) do
    """
    ## Journey Plan

    The journeys to convert into tests:

    ```markdown
    #{content}
    ```\
    """
  end

  defp build_journey_result_section(nil) do
    """
    ## Journey Result

    No journey result found. Only generate tests for journeys that have been
    verified as passing.\
    """
  end

  defp build_journey_result_section(content) do
    """
    ## Journey Result

    Only generate tests for journeys that passed:

    ```markdown
    #{content}
    ```\
    """
  end

  defp build_existing_tests_section([]), do: nil

  defp build_existing_tests_section(files) do
    file_list = Enum.map_join(files, "\n", &"- `#{&1}`")

    """
    ## Existing Tests

    These journey tests already exist — update or extend rather than duplicating:

    #{file_list}\
    """
  end

  defp build_instructions do
    """
    ## Instructions

    1. Read the journey plan and result above
    2. For each **passing** journey, write a Wallaby feature test:
       - Create test files in `#{@wallaby_dir}/`
       - Name files descriptively: `{journey_name}_test.exs`
       - Each test follows the journey steps using Wallaby browser automation
       - Assert expected outcomes from the journey plan
    3. Follow Wallaby conventions:
       - `use MyAppWeb.FeatureCase` or equivalent
       - Use `visit/2`, `fill_in/3`, `click/2`, `assert_has/2` etc.
       - Include setup for seeds/auth from the prerequisites
    4. Ensure tests are idempotent and can run independently
    5. When complete, stop the session so validation can check your work.\
    """
  end
end
