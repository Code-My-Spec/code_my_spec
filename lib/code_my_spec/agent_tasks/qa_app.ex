defmodule CodeMySpec.AgentTasks.QaApp do
  @moduledoc """
  Orchestrator task for browser-based QA of the running app.

  Analyzes the project's routes and stories, then delegates per-story QA
  testing to QaTester subagents, each of which starts its own story's
  `qa_complete` task and writes the brief from what that task returns.

  Lifecycle:
  1. Start/verify Phoenix server, via `ensure_app_running` — never a
     hand-rolled `mix phx.server &` (83aa6402: an orphaned one outlives the
     turn and starves the machine's shared analyzer slot for every other
     working copy)
  2. Smoke-test all routes (visit each, check for 500s)
  3. Dispatch `@"CodeMySpec:qa (agent)"` subagent per story
  4. Write summary to `.code_my_spec/qa/summary.md`

  Two main functions:
  - `command/3` - Returns the orchestration prompt
  - `evaluate/3` - Delegates per-story validation to QaStory.evaluate, checks summary
  """

  require Logger

  alias CodeMySpec.AgentTasks.QaStory
  alias CodeMySpec.{BddSpecs, ExecutionContexts, Issues, Paths, Stories}
  alias CodeMySpec.BddSpecs.SpecProjector

  @doc """
  The orchestration prompt: smoke-test routes, then dispatch one qa subagent
  per story. No per-story files are written; each subagent's `start_task`
  captures the review when QA actually starts.

  Returns {:ok, prompt_text}
  """
  def command(scope, _task) do
    env = CodeMySpec.AgentTasks.execution_context(scope)
    project = scope.active_project

    app_name = derive_app_name(env)
    router_content = read_router(env, app_name)
    stories = list_stories(scope)
    bdd_coverage = format_bdd_coverage(env, stories)
    bdd_summaries = format_bdd_summaries(env)
    existing_issues = list_existing_issues(scope)

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

  Delegates per-story validation to QaStory.evaluate, which checks
  brief + result artifacts and files issues for medium+ severity.

  Returns:
  - {:ok, :valid} if all stories pass and summary exists
  - {:ok, :invalid, feedback} if stories are incomplete or summary missing
  """
  def evaluate(scope, session, _opts \\ []) do
    env = CodeMySpec.AgentTasks.execution_context(scope)

    stories = list_stories(scope)
    summary_exists = summary_exists?(env)

    Logger.info("[QaApp] evaluate: #{length(stories)} story(s), summary_exists=#{summary_exists}")

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
    case ExecutionContexts.read_file(env, "mix.exs") do
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

    case ExecutionContexts.read_file(env, path) do
      {:ok, content} -> content
      _ -> nil
    end
  end

  defp list_stories(scope) do
    Stories.list_stories(scope)
  end

  defp list_existing_issues(scope) do
    issues =
      Issues.list_by_status(scope, :incoming) ++ Issues.list_by_status(scope, :accepted)

    case issues do
      [] ->
        "No existing issues."

      issues ->
        issues
        |> Enum.map(&format_issue_line/1)
        |> Enum.sort()
        |> Enum.join("\n")
    end
  end

  defp format_issue_line(issue) do
    status = if issue.status == :incoming, do: "incoming", else: "accepted"
    "- `#{status}/issue-#{issue.id}` — #{issue.title}"
  end

  defp summary_exists?(env) do
    ExecutionContexts.file_exists?(env, Paths.qa_summary()) == true
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

    Before testing, call `ensure_app_running` (no arguments — it is always
    your own copy, #{project_cwd}). It starts the app if it isn't already
    serving and verifies that its served revision matches checkout HEAD before
    giving you the URL to test against. If revision verification fails, do not
    test or submit a passing result against that instance. Use `restart_app`
    for your copy, then verify with `ensure_app_running` again. Do not start
    another restart while one is running.

    Do not start it by hand with `mix phx.server &`: a shell-backgrounded
    server is not tracked anywhere, so nothing stops it when your turn ends.
    One left running this way blocked every other working copy's analyzer
    runs behind it for 40 minutes (83aa6402) — this copy's app is a managed,
    persistent instance (it restarts on promote, not on your turn ending),
    and `ensure_app_running` is the tracked way to reach it.
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

        "### Story #{story.number} — #{story.title}\n\n#{story.description || ""}\n\n#{criteria_text}"
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
    dispatch_list =
      case stories do
        [] ->
          "  _(no stories — go straight to summary)_"

        stories ->
          Enum.map_join(stories, "\n", fn story ->
            "  - Story #{story.number}: #{story.title}"
          end)
      end

    """
    ## Instructions

    ### Step 1: Start/Verify Server

    Call `ensure_app_running` (see App Server section above) and test against
    the URL it answers with.

    ### Step 2: Smoke-Test All Routes

    Visit every route from the router using `web`. Check for 500 errors,
    missing pages, and obviously broken UI. This is a quick pass — don't
    do deep testing here.

    ### Step 3: Dispatch Per-Story QA Agents

    For each story, invoke the **qa** subagent
    (`@"CodeMySpec:qa (agent)"`) with the story number as the argument. The
    subagent starts the story's review with `start_task` (requirement_name
    `qa_complete`, entity_type `story`, entity_id the story number), writes a
    brief from what it returns, executes tests, files every finding via
    `create_issue` as it runs, and submits a structured QA attempt via
    `submit_qa_result` with the linked issue ids.

    #{dispatch_list}

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

  defp evaluate_stories(scope, _session, stories, summary_exists) do
    story_results =
      Enum.map(stories, fn story ->
        child_task = %{story_id: story.id}

        case QaStory.evaluate(scope, child_task) do
          {:ok, :valid} -> {story.number, :valid}
          {:ok, :invalid, feedback} -> {story.number, {:invalid, feedback}}
          {:error, reason} -> {story.number, {:invalid, reason}}
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
        {:ok, :invalid,
         "QA summary not found at `#{Paths.qa_summary()}`. Write the summary and stop the session again."}

      true ->
        feedback = build_evaluate_feedback(incomplete, summary_exists)
        {:ok, :invalid, feedback}
    end
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
      Enum.reduce(incomplete_stories, parts, fn {story_number, {:invalid, feedback}}, acc ->
        ["- Story #{story_number}: #{String.slice(feedback, 0..120)}" | acc]
      end)

    issue_list = parts |> Enum.reverse() |> Enum.join("\n")

    """
    QA session is incomplete:

    #{issue_list}

    Address the remaining stories and stop the session again.
    """
  end
end
