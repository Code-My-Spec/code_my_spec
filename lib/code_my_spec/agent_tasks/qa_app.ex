defmodule CodeMySpec.AgentTasks.QaApp do
  @moduledoc """
  Orchestrator task for browser-based QA of the running app.

  Analyzes the project's routes and stories, then delegates per-story QA
  testing to QaStory workers. Follows the TechnicalStrategy/ResearchTopic
  orchestration pattern.

  Lifecycle:
  1. Start/verify Phoenix server
  2. Smoke-test all routes (visit each, check for 500s)
  3. Dispatch `@"CodeMySpec:qa-story (agent)"` subagent per story
  4. Write summary to `docs/qa/summary.md`

  Two main functions:
  - `command/3` - Builds orchestration prompt with routes, stories, BDD coverage
  - `evaluate/3` - Checks QA results exist per story, validates summary
  """

  require Logger

  alias CodeMySpec.AgentTasks.QaStory
  alias CodeMySpec.{BddSpecs, Environments, Paths, Stories}
  alias CodeMySpec.BddSpecs.SpecProjector

  @doc """
  Generate the orchestration prompt for the QA session.

  Reads the router file, loads stories with acceptance criteria,
  gathers BDD spec coverage, and lists existing issues. Builds a prompt
  instructing the agent to smoke-test routes and dispatch QaStory subagents.

  Returns {:ok, prompt_text}
  """
  def command(scope, _session, _opts \\ []) do
    env = scope.environment
    project = scope.active_project

    app_name = derive_app_name(env)
    router_content = read_router(env, app_name)
    stories = list_stories(scope)
    bdd_coverage = format_bdd_coverage(env, stories)
    bdd_summaries = format_bdd_summaries(env)
    existing_issues = list_existing_issues(env)

    prompt =
      build_prompt(
        project,
        env,
        router_content,
        stories,
        bdd_coverage,
        bdd_summaries,
        existing_issues
      )

    {:ok, prompt}
  end

  @doc """
  Validate all per-story QA results are complete and summary exists.

  Loads stories, checks that each has a QA result in `docs/qa/`,
  and validates the summary exists.

  Returns:
  - {:ok, :valid} if all stories pass and summary exists
  - {:ok, :invalid, feedback} if stories are incomplete or summary missing
  """
  def evaluate(scope, session, _opts \\ []) do
    env = scope.environment

    stories = list_stories(scope)
    summary_exists = summary_exists?(env)

    Logger.info(
      "[QaApp] evaluate: #{length(stories)} story(s), summary_exists=#{summary_exists}"
    )

    if Enum.empty?(stories) and summary_exists do
      {:ok, :valid}
    else
      evaluate_stories(scope, session, stories, summary_exists)
    end
  end

  # ============================================================================
  # Data Loading
  # ============================================================================

  defp derive_app_name(env) do
    case Environments.read_file(env, "mix.exs") do
      {:ok, content} ->
        case Regex.run(~r/app:\s*:(\w+)/, content) do
          [_, app_name] -> app_name
          _ -> "my_app"
        end

      _ ->
        "my_app"
    end
  end

  defp read_router(env, app_name) do
    path = "lib/#{app_name}_web/router.ex"

    case Environments.read_file(env, path) do
      {:ok, content} -> content
      _ -> nil
    end
  end

  defp list_stories(scope) do
    Stories.list_stories(scope)
  rescue
    _ -> []
  end

  defp list_existing_issues(env) do
    case Environments.glob(env, "#{Paths.issues_dir()}/*.md") do
      files when is_list(files) and files != [] ->
        files
        |> Enum.map(&Path.basename/1)
        |> Enum.sort()
        |> Enum.map_join("\n", &"- `#{&1}`")

      _ ->
        "No existing issues."
    end
  end

  defp summary_exists?(env) do
    Environments.file_exists?(env, Paths.qa_summary()) == true
  end

  defp format_bdd_coverage(env, stories) do
    specs = BddSpecs.list_specs(env)
    SpecProjector.format_coverage(stories, specs)
  end

  defp format_bdd_summaries(env) do
    specs = BddSpecs.list_specs(env)

    if Enum.empty?(specs) do
      "No BDD specs found."
    else
      SpecProjector.project_summary_list(specs)
    end
  end

  # ============================================================================
  # Prompt Building
  # ============================================================================

  defp build_prompt(
         project,
         env,
         router_content,
         stories,
         bdd_coverage,
         bdd_summaries,
         existing_issues
       ) do
    sections =
      [
        build_header(project),
        build_server_section(env.cwd),
        build_router_section(router_content),
        build_stories_section(stories),
        build_bdd_coverage_section(bdd_coverage),
        build_bdd_details_section(bdd_summaries),
        build_existing_issues_section(existing_issues),
        build_instructions(stories)
      ]
      |> Enum.reject(&is_nil/1)

    Enum.join(sections, "\n\n")
  end

  defp build_header(project) do
    """
    # QA Session: Browser-Based App Verification

    You are orchestrating QA on the **#{project.name}** app by using the `web` CLI tool
    to smoke-test routes, then delegating per-story testing to QA subagents.

    Read the `web-cli` knowledge article for tool usage patterns and flags.
    """
  end

  defp build_server_section(project_cwd) do
    """
    ## App Server

    Before testing, ensure the Phoenix server is running:

    1. Check if the server is listening: `lsof -i -P -n | grep LISTEN`
    2. If not running, start it: `cd #{project_cwd} && mix phx.server &`
    3. Verify with `web` against the app URL
    """
  end

  defp build_router_section(nil) do
    """
    ## Router

    Could not read the router file. Run `mix phx.routes` in the project directory
    to discover available routes.
    """
  end

  defp build_router_section(router_content) do
    """
    ## Router

    Here is the app's router — this is your route map:

    ```elixir
    #{router_content}
    ```

    Use this to understand authentication pipelines, available routes, and how to navigate the app.
    """
  end

  defp build_stories_section([]) do
    """
    ## Stories

    No stories found. Perform a general route-by-route QA instead.
    """
  end

  defp build_stories_section(stories) do
    story_list =
      Enum.map_join(stories, "\n", fn story ->
        criteria_text = format_criteria(Map.get(story, :criteria, []))
        "### Story #{story.id} — #{story.title}\n\n#{story.description || ""}\n\n#{criteria_text}"
      end)

    """
    ## Stories

    #{story_list}
    """
  end

  defp format_criteria([]), do: "  _(no acceptance criteria)_"

  defp format_criteria(criteria) do
    Enum.map_join(criteria, "\n", fn c -> "  - #{c.description}" end)
  end

  defp build_bdd_coverage_section(bdd_coverage) do
    """
    ## BDD Spec Coverage

    #{bdd_coverage}
    """
  end

  defp build_bdd_details_section("No BDD specs found."), do: nil

  defp build_bdd_details_section(bdd_summaries) do
    """
    ## BDD Spec Details

    #{bdd_summaries}
    """
  end

  defp build_existing_issues_section(existing_issues) do
    """
    ## Existing Issues

    These issues are already known — don't duplicate them:

    #{existing_issues}
    """
  end

  defp build_instructions(stories) do
    story_list =
      case stories do
        [] ->
          "  _(no stories — go straight to summary)_"

        stories ->
          Enum.map_join(stories, "\n", fn story ->
            "  - Story #{story.id}: #{story.title}"
          end)
      end

    """
    ## Instructions

    ### Step 1: Start/Verify Server

    Make sure the Phoenix server is running (see App Server section above).

    ### Step 2: Smoke-Test All Routes

    Visit every route from the router using `web`. Check for 500 errors,
    missing pages, and obviously broken UI. This is a quick pass — don't
    do deep testing here.

    ### Step 3: Dispatch Per-Story QA Agents

    For each story, invoke the **qa-story** subagent
    (`@"CodeMySpec:qa-story (agent)"`) with the story ID as the argument.
    The subagent will load BDD specs, test the story, and write a result
    to `docs/qa/{story_id}.md`.

    Stories to dispatch:

    #{story_list}

    ### Step 4: Write Summary

    After all stories are tested, write a summary to `#{Paths.qa_summary()}`. Include:
    - Overall pass/fail status
    - List of stories tested with their results
    - Any cross-cutting issues found during smoke testing
    - References to filed issues

    When complete, stop the session so validation can check your work.
    """
  end

  # ============================================================================
  # Evaluation
  # ============================================================================

  defp evaluate_stories(scope, session, stories, summary_exists) do
    story_results =
      Enum.map(stories, fn story ->
        child_session = build_child_session(session, story.id)

        case QaStory.evaluate(scope, child_session) do
          {:ok, :valid} -> {story.id, :valid}
          {:ok, :invalid, feedback} -> {story.id, {:invalid, feedback}}
        end
      end)

    incomplete =
      Enum.filter(story_results, fn
        {_id, :valid} -> false
        _ -> true
      end)

    cond do
      Enum.empty?(incomplete) and summary_exists ->
        {:ok, :valid}

      not summary_exists and Enum.empty?(incomplete) ->
        {:ok, :invalid, "QA summary not found at `#{Paths.qa_summary()}`. Write the summary and stop the session again."}

      true ->
        feedback = build_evaluate_feedback(incomplete, summary_exists)
        {:ok, :invalid, feedback}
    end
  end

  defp build_child_session(session, story_id) do
    %{
      project: Map.get(session, :project),
      state: %{"topic" => story_id}
    }
  end

  defp build_evaluate_feedback(incomplete_stories, summary_exists) do
    parts = []

    parts =
      if summary_exists do
        parts
      else
        ["- QA summary not found at `#{Paths.qa_summary()}`" | parts]
      end

    parts =
      Enum.reduce(incomplete_stories, parts, fn {story_id, _status}, acc ->
        ["- Story #{story_id} is incomplete" | acc]
      end)

    issue_list = parts |> Enum.reverse() |> Enum.join("\n")

    """
    QA session is incomplete:

    #{issue_list}

    Address the remaining stories and stop the session again.
    """
  end
end
