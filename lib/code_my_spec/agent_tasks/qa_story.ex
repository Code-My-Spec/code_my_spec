defmodule CodeMySpec.AgentTasks.QaStory do
  @moduledoc """
  Per-story agent task for QA-testing a single user story.

  Loads BDD specs for the story, projects them into readable format,
  and tells the agent to test that area of the application using the
  `web` CLI tool. The agent decides how to authenticate, navigate,
  and verify — we just give it the specs and point it at the router.

  Two main functions:
  - `command/3` - Loads BDD specs, projects them, builds focused prompt
  - `evaluate/3` - Validates the QA result document exists and has required structure
  """

  require Logger

  alias CodeMySpec.{BddSpecs, Environments, Paths, Stories}
  alias CodeMySpec.BddSpecs.SpecProjector

  @doc """
  Generate the QA prompt for a single story.

  Takes a story ID from `session.state["topic"]`, loads BDD specs,
  projects them using SpecProjector, and builds a prompt pointing
  the agent at the router and specs.

  Returns {:ok, prompt_text}
  """
  def command(scope, session, _opts \\ []) do
    story_id = get_story_id(session)
    env = scope.environment

    story = Stories.get_story!(scope, story_id)
    app_name = derive_app_name(env)
    router_path = "lib/#{app_name}_web/router.ex"
    {spec_projections, spec_file_paths} = load_specs(env, story_id)
    existing_result = read_existing_result(env, story_id)
    existing_issues = list_existing_issues(env)

    prompt =
      build_prompt(
        story_id,
        story,
        router_path,
        spec_projections,
        spec_file_paths,
        existing_result,
        existing_issues
      )

    {:ok, prompt}
  end

  @doc """
  Validate the story's QA result is complete.

  Checks that `docs/qa/{story_id}.md` exists, is non-empty,
  and contains the required status line.

  Returns:
  - {:ok, :valid} if checks pass
  - {:ok, :invalid, feedback} if something is missing
  """
  def evaluate(scope, session, _opts \\ []) do
    story_id = get_story_id(session)
    env = scope.environment

    issues = check_qa_result(env, story_id, [])

    case issues do
      [] ->
        {:ok, :valid}

      issues ->
        feedback = format_feedback(story_id, issues)
        {:ok, :invalid, feedback}
    end
  end

  # ============================================================================
  # Helpers
  # ============================================================================

  defp get_story_id(%{state: %{"topic" => topic}}) do
    case Integer.parse(to_string(topic)) do
      {id, _} -> id
      :error -> raise "QaStory requires a numeric story ID in session.state[\"topic\"], got: #{inspect(topic)}"
    end
  end

  defp get_story_id(_session), do: raise("QaStory requires session.state[\"topic\"]")

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

  defp read_existing_result(env, story_id) do
    path = "#{Paths.qa_dir()}/#{story_id}.md"

    case Environments.read_file(env, path) do
      {:ok, content} -> content
      _ -> nil
    end
  end

  defp list_existing_issues(env) do
    case Environments.glob(env, "#{Paths.issues_dir()}/*.md") do
      files when is_list(files) and files != [] ->
        files
        |> Enum.map(&Path.basename/1)
        |> Enum.sort()

      _ ->
        []
    end
  end

  # ============================================================================
  # Spec Loading
  # ============================================================================

  @doc false
  def load_specs(env, story_id) do
    specs = BddSpecs.list_specs_for_story(env, story_id)

    if Enum.empty?(specs) do
      {[], []}
    else
      projections = Enum.map(specs, &SpecProjector.project_full/1)
      file_paths = Enum.map(specs, & &1.file_path)
      {projections, file_paths}
    end
  end

  # ============================================================================
  # Prompt Building
  # ============================================================================

  defp build_prompt(
         story_id,
         story,
         router_path,
         spec_projections,
         spec_file_paths,
         existing_result,
         existing_issues
       ) do
    sections =
      [
        build_header(story_id),
        build_story_section(story),
        build_specs_section(spec_projections, spec_file_paths),
        build_router_section(router_path),
        build_existing_result_section(story_id, existing_result),
        build_existing_issues_section(existing_issues),
        build_instructions(story_id),
        build_output_format(story_id)
      ]
      |> Enum.reject(&is_nil/1)

    Enum.join(sections, "\n\n")
  end

  defp build_header(story_id) do
    """
    # QA Story: #{story_id}

    You are testing story **#{story_id}** by browsing the running
    application with the `web` CLI tool. Read the `web-cli` knowledge article
    for tool usage patterns and flags.
    """
  end

  defp build_story_section(story) do
    criteria_text = format_criteria(Map.get(story, :criteria, []))

    """
    ## Story: #{story.title}

    #{story.description || "_No description._"}

    ### Acceptance Criteria

    #{criteria_text}
    """
  end

  defp format_criteria([]), do: "_No acceptance criteria defined._"

  defp format_criteria(criteria) do
    Enum.map_join(criteria, "\n", fn c -> "- #{c.description}" end)
  end

  defp build_specs_section([], []) do
    """
    ## BDD Specs

    No BDD specs found for this story. Read the router to discover relevant
    routes and test the area of the application related to this story.
    """
  end

  defp build_specs_section(projections, file_paths) do
    paths_list = Enum.map_join(file_paths, "\n", &"- `#{&1}`")
    projected_specs = Enum.join(projections, "\n\n---\n\n")

    """
    ## BDD Specs

    **Spec files** (read these for exact selectors and test data):
    #{paths_list}

    ### Projected Specs

    #{projected_specs}
    """
  end

  defp build_router_section(router_path) do
    """
    ## Router

    Read the router at `#{router_path}` to discover routes, authentication
    pipelines, and how to navigate the application.
    """
  end

  defp build_existing_result_section(_story_id, nil), do: nil

  defp build_existing_result_section(story_id, content) do
    """
    ## Existing QA Result

    A previous QA result exists at `#{Paths.qa_dir()}/#{story_id}.md`:

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

  defp build_instructions(story_id) do
    """
    ## Instructions

    1. Read the BDD spec files listed above — they contain exact element selectors,
       form data, and assertions that define what this story should do
    2. Read the router to understand authentication and available routes
    3. Ensure the Phoenix server is running
    4. Use the `web` tool to browse and test the application area covered by this story
    5. For every bug found, create an issue file in `#{Paths.issues_dir()}/#{story_id}-<description>.md`
    6. Write your QA result to `#{Paths.qa_dir()}/#{story_id}.md` using the format below
    """
  end

  defp build_output_format(story_id) do
    """
    ## Required Output Format

    Write your result to `#{Paths.qa_dir()}/#{story_id}.md` with this structure:

    ```markdown
    # QA: Story #{story_id}

    ## Status: PASS | FAIL | PARTIAL

    ## Scenarios Tested
    - [scenario name]: PASS/FAIL — [details]

    ## Issues Found
    - [description] → `docs/issues/#{story_id}-xxx.md`
    (or "None")

    ## Evidence
    - [screenshots, key observations, web tool output excerpts]
    ```

    When complete, stop the session so validation can check your work.
    """
  end

  # ============================================================================
  # Evaluation
  # ============================================================================

  defp check_qa_result(env, story_id, issues) do
    path = "#{Paths.qa_dir()}/#{story_id}.md"

    case Environments.read_file(env, path) do
      {:ok, content} when is_binary(content) ->
        content = String.trim(content)

        cond do
          content == "" ->
            [{:empty_result, "QA result at `#{path}` is empty"} | issues]

          not String.contains?(content, "## Status:") ->
            [{:missing_status, "QA result at `#{path}` is missing the `## Status:` section"} | issues]

          true ->
            issues
        end

      _ ->
        [{:missing_result, "No QA result found at `#{path}`"} | issues]
    end
  end

  defp format_feedback(story_id, issues) do
    issue_list =
      issues
      |> Enum.reverse()
      |> Enum.map_join("\n", fn {_type, message} -> "- #{message}" end)

    """
    QA story #{story_id} is incomplete:

    #{issue_list}

    Please address these issues and stop the session again.
    """
  end
end
