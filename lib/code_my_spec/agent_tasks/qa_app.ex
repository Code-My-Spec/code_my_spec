defmodule CodeMySpec.AgentTasks.QaApp do
  @moduledoc """
  Orchestrator task for browser-based QA of the running app.

  Analyzes the project's routes and stories, then delegates per-story QA
  testing to QaStory workers. Follows the TechnicalStrategy/ResearchTopic
  orchestration pattern.

  Lifecycle:
  1. Start/verify Phoenix server
  2. Smoke-test all routes (visit each, check for 500s)
  3. Write per-story QA briefs to `docs/status/qa/{story_slug}.md`
  4. Dispatch `@"CodeMySpec:qa-story (agent)"` subagent per story
  5. Write summary to `docs/qa/summary.md`

  Two main functions:
  - `command/3` - Builds orchestration prompt with routes, stories, BDD coverage
  - `evaluate/3` - Checks all story briefs via QaStory.evaluate, validates summary
  """

  require Logger

  alias CodeMySpec.AgentTasks.QaStory
  alias CodeMySpec.{BddSpecs, Environments, Stories}
  alias CodeMySpec.BddSpecs.SpecProjector

  @qa_summary "docs/qa/summary.md"
  @briefs_dir "docs/status/qa"
  @issues_dir "docs/issues"

  @doc """
  Generate the orchestration prompt for the QA session.

  Reads the router file, loads stories with slugs and acceptance criteria,
  gathers BDD spec coverage, and lists existing issues. Builds a prompt
  instructing the agent to smoke-test routes, write per-story QA briefs,
  and dispatch QaStory subagents.

  Returns {:ok, prompt_text}
  """
  def command(scope, _session, _opts \\ []) do
    env = scope.environment
    project = scope.active_project

    app_name = derive_app_name(env)
    router_content = read_router(env, app_name)
    stories = list_stories(scope)
    stories_with_slugs = build_story_slugs(stories)
    bdd_coverage = format_bdd_coverage(env, stories)
    bdd_summaries = format_bdd_summaries(env)
    existing_issues = list_existing_issues(env)

    prompt =
      build_prompt(
        project,
        env,
        router_content,
        stories_with_slugs,
        bdd_coverage,
        bdd_summaries,
        existing_issues
      )

    {:ok, prompt}
  end

  @doc """
  Validate all per-story QA results are complete and summary exists.

  Lists brief files in `docs/status/qa/` — each filename is a story slug.
  For each story, delegates to QaStory.evaluate. Also validates the
  QA summary exists.

  Returns:
  - {:ok, :valid} if all stories pass and summary exists
  - {:ok, :invalid, feedback} if stories are incomplete or summary missing
  """
  def evaluate(scope, session, _opts \\ []) do
    env = scope.environment

    story_slugs = list_qa_briefs(env)
    summary_exists = summary_exists?(env)

    Logger.info(
      "[QaApp] evaluate: #{length(story_slugs)} brief(s), summary_exists=#{summary_exists}"
    )

    if Enum.empty?(story_slugs) and summary_exists do
      {:ok, :valid}
    else
      evaluate_stories(scope, session, story_slugs, summary_exists)
    end
  end

  # ============================================================================
  # Story Slugs
  # ============================================================================

  @doc false
  def story_slug(story) do
    slug =
      story.title
      |> String.downcase()
      |> String.replace(~r/[^\w\s-]/, "")
      |> String.replace(~r/\s+/, "-")
      |> String.replace(~r/-+/, "-")
      |> String.trim("-")

    "#{story.id}-#{slug}"
  end

  defp build_story_slugs(stories) do
    Enum.map(stories, fn story ->
      {story, story_slug(story)}
    end)
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
    case Environments.glob(env, "#{@issues_dir}/*.md") do
      files when is_list(files) and files != [] ->
        files
        |> Enum.map(&Path.basename/1)
        |> Enum.sort()
        |> Enum.map_join("\n", &"- `#{&1}`")

      _ ->
        "No existing issues."
    end
  end

  defp list_qa_briefs(env) do
    case Environments.glob(env, "#{@briefs_dir}/*.md") do
      files when is_list(files) ->
        Enum.map(files, &Path.basename(&1, ".md"))

      _ ->
        []
    end
  end

  defp summary_exists?(env) do
    Environments.file_exists?(env, @qa_summary) == true
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
         stories_with_slugs,
         bdd_coverage,
         bdd_summaries,
         existing_issues
       ) do
    project_cwd = env.cwd

    sections =
      [
        build_header(project),
        build_server_section(project_cwd),
        build_router_section(router_content),
        build_stories_section(stories_with_slugs),
        build_bdd_coverage_section(bdd_coverage),
        build_bdd_details_section(bdd_summaries),
        build_existing_issues_section(existing_issues),
        build_instructions(stories_with_slugs)
      ]
      |> Enum.reject(&is_nil/1)

    Enum.join(sections, "\n\n")
  end

  defp build_header(project) do
    """
    # QA Session: Browser-Based App Verification

    You are orchestrating QA on the **#{project.name}** app by using the `web` CLI tool
    to smoke-test routes, then delegating per-story testing to QA subagents.
    """
  end

  defp build_server_section(project_cwd) do
    """
    ## App Server

    Before testing, ensure the Phoenix server is running:

    1. Check if port 4000 is already in use: `lsof -i :4000`
    2. If not running, start it in the project directory:
       `cd #{project_cwd} && mix phx.server &`
    3. Wait a few seconds, then verify: `web http://localhost:4000`
    4. If the server is already running, proceed directly.
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

    You can also run `mix phx.routes` in the project directory for a formatted list.
    """
  end

  defp build_stories_section([]) do
    """
    ## Stories

    No stories found. Perform a general route-by-route QA instead.
    """
  end

  defp build_stories_section(stories_with_slugs) do
    story_list =
      Enum.map_join(stories_with_slugs, "\n", fn {story, slug} ->
        criteria_text = format_criteria(Map.get(story, :criteria, []))
        "### `#{slug}` — #{story.title}\n\n#{story.description || ""}\n\n#{criteria_text}"
      end)

    """
    ## Stories & Slugs

    Each story has a slug used for file naming. Write QA briefs and results
    using these exact slugs:

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

    This shows which stories have automated BDD tests and which don't.
    Pay extra attention to stories with no coverage — those are the most
    likely to have untested bugs:

    #{bdd_coverage}
    """
  end

  defp build_bdd_details_section("No BDD specs found."), do: nil

  defp build_bdd_details_section(bdd_summaries) do
    """
    ## BDD Spec Details

    These are the actual BDD test scenarios. Review them to understand what's
    already being tested (and what's not):

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

  defp build_instructions(stories_with_slugs) do
    slug_list =
      case stories_with_slugs do
        [] ->
          "  _(no stories — skip brief writing and go straight to summary)_"

        slugs ->
          Enum.map_join(slugs, "\n", fn {_story, slug} ->
            "  - `docs/status/qa/#{slug}.md`"
          end)
      end

    """
    ## Instructions

    ### Step 1: Start/Verify Server

    Make sure the Phoenix server is running (see App Server section above).

    ### Step 2: Smoke-Test All Routes

    Visit every route from the router using `web`. Check for 500 errors,
    missing pages, and obviously broken UI. Use `--profile qa` to maintain session.

    ### Step 3: Write Per-Story QA Briefs

    For each story, write a QA brief to `docs/status/qa/{story_slug}.md`.
    The brief should include:
    - Story title and relevant acceptance criteria
    - Which routes to test for this story
    - What to look for (based on your smoke test observations)
    - Any authentication or setup steps needed

    Briefs to write:

    #{slug_list}

    ### Step 4: Dispatch Per-Story QA Agents

    For each brief, invoke the **qa-story** subagent
    (`@"CodeMySpec:qa-story (agent)"`) with the story slug as the argument.
    The subagent will read the brief, test the story, and write a result
    to `docs/qa/{story_slug}.md`.

    ### Step 5: Write Summary

    After all stories are tested, write a summary to `#{@qa_summary}`. Include:
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

  defp evaluate_stories(scope, session, story_slugs, summary_exists) do
    story_results =
      Enum.map(story_slugs, fn slug ->
        child_session = build_child_session(session, slug)

        case QaStory.evaluate(scope, child_session) do
          {:ok, :valid} -> {slug, :valid}
          {:ok, :invalid, feedback} -> {slug, {:invalid, feedback}}
        end
      end)

    incomplete =
      Enum.filter(story_results, fn
        {_slug, :valid} -> false
        _ -> true
      end)

    cond do
      Enum.empty?(incomplete) and summary_exists ->
        {:ok, :valid}

      not summary_exists ->
        feedback = build_evaluate_feedback(incomplete, false)
        {:ok, :invalid, feedback}

      true ->
        feedback = build_evaluate_feedback(incomplete, true)
        {:ok, :invalid, feedback}
    end
  end

  defp build_child_session(session, story_slug) do
    %{
      project: Map.get(session, :project),
      state: %{"topic" => story_slug}
    }
  end

  defp build_evaluate_feedback(incomplete_stories, summary_exists) do
    parts = []

    parts =
      if summary_exists do
        parts
      else
        ["- QA summary not found at `#{@qa_summary}`" | parts]
      end

    parts =
      Enum.reduce(incomplete_stories, parts, fn {slug, _status}, acc ->
        ["- Story \"#{slug}\" is incomplete" | acc]
      end)

    issue_list = parts |> Enum.reverse() |> Enum.join("\n")

    """
    QA session is incomplete:

    #{issue_list}

    Address the remaining stories and stop the session again.
    """
  end
end
