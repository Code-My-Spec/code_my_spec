defmodule CodeMySpec.AgentTasks.QaPreflight do
  @moduledoc """
  Pre-QA integration verification agent task.

  Runs after all stories are complete but before any QA testing begins.
  Verifies that the app's integrations work end-to-end in the running application:

  1. Reads integration specs to know what to verify
  2. Starts the app and runs seeds
  3. Executes verify scripts against the app's own endpoints
  4. Runs integration tests
  5. Produces a preflight report

  Two main functions:
  - `command/3` — Builds prompt to verify integrations against the running app
  - `evaluate/3` — Checks preflight report exists and all integrations are verified
  """


  def orchestrate(node) do
    "Call `start_task` with requirement `#{node.name}` for #{node.entity_type} `#{node.entity_id}` (#{node.entity_name})"
  end

  alias CodeMySpec.{Environments, Paths}

  @integrations_dir Paths.integrations_dir()
  @integrations_index Paths.integrations_index()
  @preflight_report Path.join(Paths.qa_dir(), "preflight.md")
  @scripts_dir Paths.qa_scripts_dir()

  @doc """
  Generate the preflight verification prompt.

  Reads integration specs and builds a prompt instructing the agent to verify
  each integration works against the running app.
  """
  def command(scope, _task) do
    env = scope.environment

    integration_specs = read_integration_specs(env)
    existing_report = read_existing_report(env)
    qa_plan = read_qa_plan(env)

    prompt = build_prompt(integration_specs, existing_report, qa_plan)

    {:ok, prompt}
  end

  @doc """
  Validate preflight output.

  Checks:
  - Preflight report exists
  - All integration specs remain at `verified` status
  """
  def evaluate(scope, _task) do
    env = scope.environment

    with :ok <- check_report(env),
         :ok <- check_integrations(env) do
      {:ok, :valid}
    else
      {:error, feedback} ->
        {:ok, :invalid, feedback}
    end
  end

  # ============================================================================
  # Data Loading
  # ============================================================================

  defp read_integration_specs(env) do
    case Environments.glob(env, Path.join(@integrations_dir, "*.md")) do
      files when is_list(files) and files != [] ->
        files
        |> Enum.map(&read_integration_spec(env, &1))
        |> Enum.reject(&is_nil/1)

      _ ->
        []
    end
  end

  defp read_integration_spec(env, file) do
    case Environments.read_file(env, file) do
      {:ok, content} -> {file, content}
      _ -> nil
    end
  end

  defp read_existing_report(env) do
    case Environments.read_file(env, @preflight_report) do
      {:ok, content} when byte_size(content) > 0 -> content
      _ -> nil
    end
  end

  defp read_qa_plan(env) do
    case Environments.read_file(env, Paths.qa_plan()) do
      {:ok, content} when byte_size(content) > 0 -> content
      _ -> nil
    end
  end

  # ============================================================================
  # Prompt Building
  # ============================================================================

  defp build_prompt(integration_specs, existing_report, qa_plan) do
    sections =
      [
        build_header(),
        build_integration_specs_section(integration_specs),
        build_qa_plan_section(qa_plan),
        build_existing_report_section(existing_report),
        build_instructions()
      ]
      |> Enum.reject(&is_nil/1)

    Enum.join(sections, "\n\n")
  end

  defp build_header do
    """
    # QA Preflight: App-Level Integration Verification

    You are running preflight checks to verify that the app's integrations work end-to-end.
    The integration credentials were already verified pre-bootstrap. Now you need to confirm
    that the app-level code (provider modules, OAuth controllers, API clients) works correctly
    in the running application.

    This step gates all QA testing — no point testing features if integrations are broken.\
    """
  end

  defp build_integration_specs_section([]) do
    """
    ## Integration Specs

    No integration specs found. Check `#{@integrations_index}` to see if integrations
    are expected. If no integrations are needed, write a preflight report noting this
    and stop the session.\
    """
  end

  defp build_integration_specs_section(specs) do
    spec_summaries =
      Enum.map_join(specs, "\n\n", fn {file, content} ->
        truncated = String.slice(content, 0, 500)
        "### `#{file}`\n\n#{truncated}"
      end)

    """
    ## Integration Specs

    The following integrations need verification against the running app:

    #{spec_summaries}\
    """
  end

  defp build_qa_plan_section(nil), do: nil

  defp build_qa_plan_section(_content) do
    """
    ## QA Plan

    A QA plan exists at `#{Paths.qa_plan()}`. Read it for app overview, auth details,
    and seed strategy before running preflight checks.\
    """
  end

  defp build_existing_report_section(nil), do: nil

  defp build_existing_report_section(_content) do
    """
    ## Existing Report

    A preflight report already exists at `#{@preflight_report}`. Read it and update
    rather than starting from scratch.\
    """
  end

  defp build_instructions do
    """
    ## Instructions

    ### Step 1: Start the App

    1. Ensure the app compiles: `mix compile`
    2. Run migrations: `mix ecto.migrate`
    3. Start the server: `mix phx.server` (or confirm it's already running)
    4. Run seed scripts if needed

    ### Step 2: Verify Each Integration

    For each integration spec in `#{@integrations_dir}/`:

    1. Read the spec to understand what's being verified
    2. Run the verify script from `#{@scripts_dir}/` against the app's endpoints
       (not direct API calls — those were pre-bootstrap)
    3. Check the JSON output for `"status": "ok"`
    4. If verification fails, investigate and fix the app-level integration code

    ### Step 3: Run Integration Tests

    If integration test files exist, run them:
    ```
    mix test test/integration/
    ```

    ### Step 4: Write Preflight Report

    Write `#{@preflight_report}` documenting:
    - Which integrations were verified
    - Results of each verification (pass/fail with details)
    - Any issues found and how they were resolved
    - Overall preflight status (pass/fail)

    When all integrations are verified, stop the session so validation can check your work.\
    """
  end

  # ============================================================================
  # Evaluation
  # ============================================================================

  defp check_report(env) do
    case Environments.read_file(env, @preflight_report) do
      {:ok, content} when byte_size(content) > 0 -> :ok
      {:ok, _} -> {:error, "Preflight report is empty. Write `#{@preflight_report}` and stop again."}
      _ -> {:error, "Preflight report not found at `#{@preflight_report}`. Write it and stop again."}
    end
  end

  defp check_integrations(env) do
    case Environments.read_file(env, @integrations_index) do
      {:ok, content} when byte_size(content) > 0 ->
        if String.contains?(String.downcase(content), "no integrations") do
          :ok
        else
          check_all_verified(env)
        end

      _ ->
        {:error, "Integration index missing. Run qa_integration_plan first."}
    end
  end

  defp check_all_verified(env) do
    case Environments.glob(env, Path.join(@integrations_dir, "*.md")) do
      files when is_list(files) and files != [] ->
        Enum.reduce_while(files, :ok, fn file, :ok -> verify_integration_spec(env, file) end)

      _ ->
        {:error, "No integration specs found but index implies integrations are needed."}
    end
  end

  defp verify_integration_spec(env, file) do
    case Environments.read_file(env, file) do
      {:ok, content} ->
        if String.contains?(String.downcase(content), "verified"),
          do: {:cont, :ok},
          else:
            {:halt,
             {:error,
              "Integration `#{file}` is not verified. Run the verify script against the app."}}

      _ ->
        {:halt, {:error, "Cannot read integration spec `#{file}`."}}
    end
  end
end
