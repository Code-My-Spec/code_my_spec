defmodule CodeMySpec.AgentTasks.QaStory do
  @moduledoc """
  Per-story agent task for QA-testing a single user story.

  Handles testing one story via the `web` CLI tool and producing its artifacts:
  - A QA result at `docs/qa/{story_slug}.md`
  - Optionally, issue files in `docs/issues/`

  Can be invoked standalone or delegated to by QaApp.

  Two main functions:
  - `command/3` - Reads QA brief and existing result, builds focused prompt
  - `evaluate/3` - Validates the story has a QA result and cleans up brief
  """

  alias CodeMySpec.Environments

  @qa_dir "docs/qa"
  @briefs_dir "docs/status/qa"
  @issues_dir "docs/issues"

  @doc """
  Generate the QA prompt for a single story.

  Reads the QA brief (if one exists), checks for an existing result,
  lists existing issues, and builds a prompt instructing the agent to
  test the story using the `web` tool.

  The story slug is taken from `session.state["topic"]`.

  Returns {:ok, prompt_text}
  """
  def command(scope, session, _opts \\ []) do
    story_slug = get_topic(session)
    env = scope.environment

    qa_brief = read_qa_brief(env, story_slug)
    existing_result = read_existing_result(env, story_slug)
    existing_issues = list_existing_issues(env)

    prompt = build_prompt(story_slug, qa_brief, existing_result, existing_issues)
    {:ok, prompt}
  end

  @doc """
  Validate the story's QA result is complete.

  Checks:
  1. QA result exists at `docs/qa/{story_slug}.md` and is non-empty
  2. On success, cleans up the QA brief file

  Returns:
  - {:ok, :valid} if checks pass
  - {:ok, :invalid, feedback} if something is missing
  """
  def evaluate(scope, session, _opts \\ []) do
    story_slug = get_topic(session)
    env = scope.environment
    working_dir = env && env.cwd

    issues = []
    issues = check_qa_result(env, story_slug, issues)

    case issues do
      [] ->
        cleanup_qa_brief(story_slug, working_dir)
        {:ok, :valid}

      issues ->
        feedback = format_feedback(story_slug, issues)
        {:ok, :invalid, feedback}
    end
  end

  # ============================================================================
  # Helpers
  # ============================================================================

  defp get_topic(%{state: %{"topic" => topic}}), do: topic
  defp get_topic(_session), do: raise("QaStory requires session.state[\"topic\"]")

  defp read_qa_brief(env, story_slug) do
    path = "#{@briefs_dir}/#{story_slug}.md"

    case Environments.read_file(env, path) do
      {:ok, content} -> content
      _ -> nil
    end
  end

  defp read_existing_result(env, story_slug) do
    path = "#{@qa_dir}/#{story_slug}.md"

    case Environments.read_file(env, path) do
      {:ok, content} -> content
      _ -> nil
    end
  end

  defp list_existing_issues(env) do
    case Environments.glob(env, "#{@issues_dir}/*.md") do
      files when is_list(files) and files != [] ->
        files
        |> Enum.map(&Path.basename/1)
        |> Enum.sort()

      _ ->
        []
    end
  end

  # ============================================================================
  # Prompt Building
  # ============================================================================

  defp build_prompt(story_slug, qa_brief, existing_result, existing_issues) do
    sections =
      [
        build_header(story_slug),
        build_brief_section(qa_brief),
        build_existing_result_section(story_slug, existing_result),
        build_existing_issues_section(existing_issues),
        build_instructions(story_slug)
      ]
      |> Enum.reject(&is_nil/1)

    Enum.join(sections, "\n\n")
  end

  defp build_header(story_slug) do
    """
    # QA Story: #{story_slug}

    You are testing the user story **#{story_slug}** by using the `web` CLI tool
    to browse the running application and verify it works correctly.
    """
  end

  defp build_brief_section(nil), do: nil

  defp build_brief_section(brief) do
    """
    ## QA Brief

    The following brief describes what to test for this story:

    #{brief}
    """
  end

  defp build_existing_result_section(_story_slug, nil), do: nil

  defp build_existing_result_section(story_slug, content) do
    """
    ## Existing QA Result

    A previous QA result exists at `#{@qa_dir}/#{story_slug}.md`:

    ```markdown
    #{content}
    ```

    Review and update this rather than starting from scratch.
    """
  end

  defp build_existing_issues_section([]), do: nil

  defp build_existing_issues_section(issues) do
    issue_list = Enum.map_join(issues, "\n", &"- `#{&1}`")

    """
    ## Existing Issues

    These issues are already known — don't duplicate them:

    #{issue_list}
    """
  end

  defp build_instructions(story_slug) do
    """
    ## Instructions

    ### Using the `web` tool

    - **Visit a page**: `web http://localhost:4000/some-route`
    - **Take a screenshot**: `web http://localhost:4000/some-route --screenshot docs/qa/screenshots/#{story_slug}/page.png`
    - **Fill a form**: `web http://localhost:4000/page --form "form_id" --input "field[name]" --value "test" --after-submit http://localhost:4000/next`
    - **JS interactions**: `web http://localhost:4000/page --js "document.querySelector('.btn').click()"`
    - **Maintain session**: Use `--profile qa` on all requests to keep cookies/auth

    ### For authenticated routes

    1. First log in using the app's login form with `--profile qa`
    2. Then visit authenticated routes with `--profile qa` to reuse the session

    ### Testing approach

    1. Focus on the routes and functionality related to this story
    2. Test the happy path first, then edge cases
    3. Check page content against acceptance criteria from the brief
    4. Look for: broken pages, missing content, form errors, UI glitches, 500 errors

    ### Filing issues

    For every bug or problem you find, create an issue file in `#{@issues_dir}/`:

    - Filename: descriptive kebab-case, e.g. `#{@issues_dir}/#{story_slug}-form-500-error.md`
    - Content: describe the problem, what you expected, what happened, and the route

    ### Write QA Result

    Write the result to `#{@qa_dir}/#{story_slug}.md`. Include:

    - What routes you visited for this story
    - What you tested (happy path, edge cases)
    - What passed and what failed
    - References to any issues you filed

    When complete, stop the session so validation can check your work.
    """
  end

  # ============================================================================
  # Evaluation
  # ============================================================================

  defp check_qa_result(env, story_slug, issues) do
    path = "#{@qa_dir}/#{story_slug}.md"

    case Environments.read_file(env, path) do
      {:ok, content} when is_binary(content) ->
        if String.trim(content) == "" do
          [{:empty_result, "QA result at `#{path}` is empty"} | issues]
        else
          issues
        end

      _ ->
        [{:missing_result, "No QA result found at `#{path}`"} | issues]
    end
  end

  defp cleanup_qa_brief(_story_slug, nil), do: :ok

  defp cleanup_qa_brief(story_slug, working_dir) do
    path = Path.join(working_dir, "#{@briefs_dir}/#{story_slug}.md")

    if File.exists?(path) do
      File.rm(path)
    end

    :ok
  end

  defp format_feedback(story_slug, issues) do
    issue_list =
      issues
      |> Enum.reverse()
      |> Enum.map_join("\n", fn {_type, message} -> "- #{message}" end)

    """
    QA story "#{story_slug}" is incomplete:

    #{issue_list}

    Please address these issues and stop the session again.
    """
  end
end
