defmodule CodeMySpec.AgentTasks.QaApp do
  @moduledoc """
  Browser-based QA agent task for verifying the running app.

  A componentless, project-wide task that instructs the agent to browse the
  running application using the `web` CLI tool. The agent reads the router
  to discover routes, visits each one, tests forms, and files issues for
  anything broken.

  Two main functions:
  - `command/3` - Gathers router, stories, BDD specs, and existing issues,
    then builds a QA prompt
  - `evaluate/3` - Validates the QA report exists and references stories
  """

  require Logger

  alias CodeMySpec.{BddSpecs, Environments, Stories}
  alias CodeMySpec.BddSpecs.SpecProjector

  @qa_report "docs/qa/report.md"
  @issues_dir "docs/issues"

  @doc """
  Generate the QA session prompt.

  Reads the router file, loads stories with acceptance criteria, gathers BDD
  spec coverage, reads spec files for detail, and lists existing issues.
  Builds a prompt instructing the agent to browse the app and validate routes.

  Returns {:ok, prompt_text}
  """
  def command(scope, _session, _opts \\ []) do
    env = scope.environment
    project = scope.active_project

    app_name = derive_app_name(env)
    router_content = read_router(env, app_name)
    stories = list_stories(scope)
    stories_text = format_stories_with_criteria(stories)
    bdd_coverage = format_bdd_coverage(env, stories)
    bdd_summaries = format_bdd_summaries(env)
    existing_issues = list_existing_issues(env)

    prompt =
      build_prompt(
        project,
        env,
        router_content,
        stories_text,
        bdd_coverage,
        bdd_summaries,
        existing_issues
      )

    {:ok, prompt}
  end

  @doc """
  Validate the QA session produced a report.

  Checks:
  1. `docs/qa/report.md` exists and is non-empty
  2. The report references at least one story title

  Returns:
  - {:ok, :valid} if both checks pass
  - {:ok, :invalid, feedback} if something is missing
  """
  def evaluate(scope, _session, _opts \\ []) do
    env = scope.environment

    issues = []
    issues = check_report_exists(env, issues)
    issues = check_report_references_stories(env, scope, issues)

    case issues do
      [] ->
        {:ok, :valid}

      issues ->
        feedback = format_feedback(issues)
        {:ok, :invalid, feedback}
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

  defp format_stories_with_criteria([]), do: "No stories found."

  defp format_stories_with_criteria(stories) do
    Enum.map_join(stories, "\n\n", &format_story_with_criteria/1)
  end

  defp format_story_with_criteria(story) do
    criteria = Map.get(story, :criteria, [])
    criteria_text = format_criteria_list(criteria)

    "### #{story.title}\n\n#{story.description || ""}\n\n**Acceptance Criteria:**\n#{criteria_text}"
  end

  defp format_criteria_list([]), do: "  _(no acceptance criteria defined)_"

  defp format_criteria_list(criteria) do
    Enum.map_join(criteria, "\n", fn c -> "  - #{c.description}" end)
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

  # ============================================================================
  # Prompt Building
  # ============================================================================

  defp build_prompt(
         project,
         env,
         router_content,
         stories_text,
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
        build_stories_section(stories_text),
        build_bdd_coverage_section(bdd_coverage),
        build_bdd_details_section(bdd_summaries),
        build_existing_issues_section(existing_issues),
        build_instructions()
      ]
      |> Enum.reject(&is_nil/1)

    Enum.join(sections, "\n\n")
  end

  defp build_header(project) do
    """
    # QA Session: Browser-Based App Verification

    You are performing QA on the **#{project.name}** app by using the `web` CLI tool
    to browse the running application and verify it works correctly.

    Your job is to validate what's actually there — visit every route, try the forms,
    check the content, and file issues for anything broken.
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

  defp build_stories_section(stories_text) do
    """
    ## Stories & Acceptance Criteria

    These stories describe what the app should do. Use them as context when
    evaluating pages, but test what's actually there:

    #{stories_text}
    """
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

  defp build_instructions do
    """
    ## Instructions

    ### Using the `web` tool

    - **Visit a page**: `web http://localhost:4000/some-route`
    - **Take a screenshot**: `web http://localhost:4000/some-route --screenshot docs/qa/screenshots/route-name.png`
    - **Fill a form**: `web http://localhost:4000/page --form "form_id" --input "field[name]" --value "test" --after-submit http://localhost:4000/next`
    - **JS interactions**: `web http://localhost:4000/page --js "document.querySelector('.btn').click()"`
    - **Maintain session**: Use `--profile qa` on all requests to keep cookies/auth

    ### For authenticated routes

    1. First log in using the app's login form with `--profile qa`
    2. Then visit authenticated routes with `--profile qa` to reuse the session

    ### Testing approach

    1. Start with the root route and navigate through the app
    2. Visit every route from the router
    3. Try form submissions — happy path and edge cases
    4. Check page content against story acceptance criteria
    5. Look for: broken pages, missing content, form errors, UI glitches, 500 errors

    ### Filing issues

    For every bug or problem you find, create an issue file in `docs/issues/`:

    - Filename: descriptive kebab-case, e.g. `docs/issues/login-form-500-error.md`
    - Content: describe the problem, what you expected, what happened, and the route

    ### Write QA Report

    Write the report to `docs/qa/report.md`. Include:

    - What routes you visited
    - What you tested
    - What passed and what failed
    - References to any issues you filed

    When complete, stop the session so validation can check your work.
    """
  end

  # ============================================================================
  # Evaluation
  # ============================================================================

  defp check_report_exists(env, issues) do
    case Environments.read_file(env, @qa_report) do
      {:ok, content} when is_binary(content) ->
        if String.trim(content) == "" do
          [{:empty_report, "QA report at `#{@qa_report}` is empty"} | issues]
        else
          issues
        end

      _ ->
        [{:missing_report, "QA report not found at `#{@qa_report}`"} | issues]
    end
  end

  defp check_report_references_stories(env, scope, issues) do
    # Only check story references if the report exists
    case Environments.read_file(env, @qa_report) do
      {:ok, report_content} when is_binary(report_content) and report_content != "" ->
        story_titles = get_story_titles(scope)
        validate_story_references(report_content, story_titles, issues)

      _ ->
        # Report doesn't exist — that's handled by check_report_exists
        issues
    end
  end

  defp validate_story_references(_report_content, [], issues), do: issues

  defp validate_story_references(report_content, story_titles, issues) do
    has_reference =
      Enum.any?(story_titles, fn title ->
        String.contains?(report_content, title)
      end)

    if has_reference do
      issues
    else
      [{:no_story_references,
        "QA report does not reference any story titles. " <>
          "Include story names in the report to show what was tested."} | issues]
    end
  end

  defp get_story_titles(scope) do
    Stories.list_story_titles(scope)
    |> Enum.map(& &1.title)
  rescue
    _ -> []
  end

  defp format_feedback(issues) do
    issue_list =
      issues
      |> Enum.reverse()
      |> Enum.map_join("\n", fn {_type, message} -> "- #{message}" end)

    """
    QA session is incomplete:

    #{issue_list}

    Please address these issues and stop the session again.
    """
  end
end
