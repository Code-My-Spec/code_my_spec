defmodule CodeMySpec.AgentTasks.QaJourneyExecute do
  @moduledoc """
  Executes QA journeys from the journey plan using browser tools.

  Reads the journey plan and builds a prompt instructing the agent to execute
  each journey with browser tools, writing results to `.code_my_spec/qa/journey_result.md`.

  Two main functions:
  - `command/3` — Builds prompt to execute journeys and write journey_result.md
  - `evaluate/3` — Checks required sections exist (status, journey results)
  """

  alias CodeMySpec.Documents.DocumentSpecProjector
  alias CodeMySpec.{Environments, Paths}

  @required_sections ["status", "journey results"]

  @doc """
  Generate the execution prompt for the QA journey execute session.

  Reads the journey plan and builds a prompt instructing the agent to execute
  each journey with browser tools and write the result document.

  Returns `{:ok, prompt_text}`
  """
  def command(scope, _task) do
    env = scope.environment

    journey_plan = read_file(env, Paths.qa_journey_plan())
    qa_plan = read_file(env, Paths.qa_plan())
    doc_spec = DocumentSpecProjector.project_spec("qa_journey_result")

    prompt = build_prompt(journey_plan, qa_plan, doc_spec, env)

    {:ok, prompt}
  end

  @doc """
  Validate that journey_result.md exists and contains the required sections.

  Returns:
  - `{:ok, :valid}` if journey_result.md exists with all required sections
  - `{:ok, :invalid, feedback}` if missing or incomplete
  """
  def evaluate(scope, _task) do
    env = scope.environment
    result_path = Paths.qa_journey_result()

    case Environments.read_file(env, result_path) do
      {:ok, content} when byte_size(content) > 0 ->
        validate_sections(content)

      _ ->
        {:ok, :invalid,
         "Journey result not found at `#{result_path}`. Execute the journeys and stop the session again."}
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

  # ============================================================================
  # Prompt Building
  # ============================================================================

  defp build_prompt(journey_plan, qa_plan, doc_spec, env) do
    sections =
      [
        build_header(),
        build_doc_spec_section(doc_spec),
        build_journey_plan_section(journey_plan),
        build_qa_plan_section(qa_plan),
        build_server_section(env.cwd),
        build_instructions()
      ]
      |> Enum.reject(&is_nil/1)

    Enum.join(sections, "\n\n")
  end

  defp build_header do
    """
    # QA Journey Execution

    You are executing end-to-end QA journeys against the running application using
    browser tools. Follow each journey from the plan step by step, recording results
    and capturing evidence.\
    """
  end

  defp build_doc_spec_section(doc_spec) do
    """
    ## Document Format

    Write the journey result to `#{Paths.qa_journey_result()}` following this specification:

    #{doc_spec}\
    """
  end

  defp build_journey_plan_section(nil) do
    """
    ## Journey Plan

    No journey plan found at `#{Paths.qa_journey_plan()}`. Cannot execute journeys
    without a plan. This task should not have been started.\
    """
  end

  defp build_journey_plan_section(content) do
    """
    ## Journey Plan

    Execute each journey defined in this plan:

    ```markdown
    #{content}
    ```\
    """
  end

  defp build_qa_plan_section(nil), do: nil

  defp build_qa_plan_section(content) do
    """
    ## QA Infrastructure

    Reference the QA plan for tools, auth, and seed strategy:

    ```markdown
    #{content}
    ```\
    """
  end

  defp build_server_section(project_cwd) do
    """
    ## App Server

    Before testing, ensure the Phoenix server is running:

    1. Check if the server is listening: `lsof -i -P -n | grep LISTEN`
    2. If not running, start it: `cd #{project_cwd} && mix phx.server &`
    3. Verify with browser tools against the app URL\
    """
  end

  defp build_instructions do
    """
    ## Instructions

    1. Ensure the Phoenix server is running
    2. Run seed scripts from the journey plan prerequisites
    3. Execute each journey step by step using browser tools
    4. For each journey, record:
       - Whether it passed or failed
       - Steps taken and observations
       - Screenshots as evidence
    5. Write the result to `#{Paths.qa_journey_result()}`
    6. Set the overall status (pass/fail/partial)
    7. When complete, stop the session so validation can check your work.\
    """
  end

  # ============================================================================
  # Validation
  # ============================================================================

  defp validate_sections(content) do
    content_lower = String.downcase(content)

    missing =
      Enum.reject(@required_sections, fn section ->
        String.contains?(content_lower, "## #{section}")
      end)

    case missing do
      [] ->
        {:ok, :valid}

      sections ->
        section_list = Enum.map_join(sections, ", ", &"`## #{title_case(&1)}`")

        {:ok, :invalid,
         "Journey result is missing required section(s): #{section_list}. Update the result and stop the session again."}
    end
  end

  defp title_case(string) do
    string
    |> String.split(" ")
    |> Enum.map_join(" ", &String.capitalize/1)
  end
end
