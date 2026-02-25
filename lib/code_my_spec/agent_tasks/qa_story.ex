defmodule CodeMySpec.AgentTasks.QaStory do
  @moduledoc """
  Per-story QA agent that plans and tests a single user story.

  Takes a story ID from `session.state["topic"]`, writes
  `.code_my_spec/qa/{story_id}/prompt.md` with story metadata and BDD spec paths,
  then returns a prompt telling the agent to write a brief and stop.

  Evaluate is a state machine — phase is derived from artifact existence:
  1. **brief** — brief.md missing or invalid → feedback to write the brief
  2. **test** — brief valid, result.md missing or invalid → feedback to test
  3. **done** — both valid → parse issues from result, create issue files for medium+

  Three artifacts for inspectability:
  - `prompt.md` — story context (written by this code)
  - `brief.md` — agent's plan of attack (written by the agent)
  - `result.md` — test outcomes with evidence (written by the agent)

  Two main functions:
  - `command/3` — Writes prompt.md to disk, returns agent prompt (phase 1 only)
  - `evaluate/3` — State machine: validates brief → result → files issues
  """

  require Logger

  alias CodeMySpec.{BddSpecs, Environments, Paths, Stories}
  alias CodeMySpec.Documents
  alias CodeMySpec.Documents.{DocumentSpecProjector, QaIssue}

  @doc """
  Write the story's prompt.md and return the agent prompt.

  1. Loads the story and its BDD spec file paths
  2. Writes `.code_my_spec/qa/{story_id}/prompt.md` with story context
  3. Returns a prompt for phase 1 only — write the brief and stop

  Returns `{:ok, prompt_text}`
  """
  def command(scope, session, _opts \\ []) do
    with {:ok, story_id} <- get_story_id(session) do
      env = scope.environment

      story = Stories.get_story!(scope, story_id)
      spec_paths = collect_spec_file_paths(env, story_id)
      prompt_path = prompt_path(story_id)
      brief_path = brief_path(story_id)

      # Write the prompt file to disk as shared context
      prompt_content = build_prompt_file(story, spec_paths)
      Environments.write_file(env, prompt_path, prompt_content)

      # Return agent prompt pointing to the files
      plan_exists = plan_exists?(env)
      existing_scripts = list_scripts(env)
      brief_spec = DocumentSpecProjector.project_spec("qa_story_brief")

      agent_prompt =
        build_agent_prompt(
          story_id,
          prompt_path,
          brief_path,
          plan_exists,
          existing_scripts,
          brief_spec
        )

      {:ok, agent_prompt}
    end
  end

  @doc """
  State machine evaluate — phase is derived from artifact existence.

  Phase flow:
  1. brief.md missing/invalid → feedback to write the brief
  2. brief valid, result.md missing/invalid → feedback to execute tests
  3. both valid → parse issues, create files for medium+, return valid

  Returns:
  - `{:ok, :valid}` when both brief and result pass validation (issues filed inline)
  - `{:ok, :invalid, feedback}` when the current phase artifact is missing or invalid
  """
  def evaluate(scope, session, _opts \\ []) do
    with {:ok, story_id} <- get_story_id(session) do
      env = scope.environment

      case check_brief(env, story_id) do
        {:missing, feedback} ->
          {:ok, :invalid, feedback}

        :valid ->
          case check_result(env, story_id) do
            {:missing, feedback} ->
              {:ok, :invalid, feedback}

            {:valid, document} ->
              create_issue_files(env, story_id, document)
              {:ok, :valid}
          end
      end
    end
  end

  # ============================================================================
  # Session Helpers
  # ============================================================================

  defp get_story_id(%{state: %{"topic" => topic}}) when not is_nil(topic) do
    case Integer.parse(to_string(topic)) do
      {id, _} -> {:ok, id}
      :error -> {:error, "QaStory requires a numeric story ID, got: #{inspect(topic)}"}
    end
  end

  defp get_story_id(_session) do
    {:error, "QaStory requires a story ID argument. Usage: /qa-story <story_id>"}
  end

  # ============================================================================
  # Phase Checks
  # ============================================================================

  defp check_brief(env, story_id) do
    path = brief_path(story_id)

    case Environments.read_file(env, path) do
      {:ok, content} when is_binary(content) and byte_size(content) > 0 ->
        case Documents.create_dynamic_document(content, "qa_story_brief") do
          {:ok, _document} ->
            :valid

          {:error, reason} ->
            {:missing,
             "Brief at `#{path}` is invalid: #{reason}. Fix the brief and stop the session again."}
        end

      _ ->
        {:missing,
         "Brief not found at `#{path}`. Write the brief following the format specification, then stop the session."}
    end
  end

  defp check_result(env, story_id) do
    path = result_path(story_id)
    result_spec = DocumentSpecProjector.project_spec("qa_result")

    case Environments.read_file(env, path) do
      {:ok, content} when is_binary(content) and byte_size(content) > 0 ->
        case Documents.create_dynamic_document(content, "qa_result") do
          {:ok, document} ->
            {:valid, document}

          {:error, reason} ->
            {:missing,
             "Brief validated. Result at `#{path}` is invalid: #{reason}. " <>
               "Fix the result to match this specification and stop the session.\n\n" <>
               result_spec}
        end

      _ ->
        screenshot_dir = Path.join([Paths.qa_dir(), to_string(story_id), "screenshots"])

        {:missing,
         "Brief validated. Now execute the test plan from the brief and write the result to `#{path}`. " <>
           "Save screenshots to `#{screenshot_dir}/`. " <>
           "Stop the session when done.\n\n## Result Format\n\n" <>
           result_spec}
    end
  end

  # ============================================================================
  # Issue Filing
  # ============================================================================

  defp create_issue_files(env, story_id, document) do
    issues = Map.get(document.sections, "issues", [])

    if is_list(issues) do
      issues
      |> Enum.filter(&QaIssue.fileable?/1)
      |> Enum.each(&maybe_write_issue_file(env, story_id, &1))
    end
  end

  defp maybe_write_issue_file(env, story_id, issue) do
    slug =
      issue.title
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9]+/, "_")
      |> String.trim_leading("_")
      |> String.trim_trailing("_")
      |> String.slice(0..40)

    path = Path.join(Paths.issues_dir(), "qa-#{story_id}-#{slug}.md")

    unless Environments.file_exists?(env, path) do
      content = build_issue_file(story_id, issue)
      Environments.write_file(env, path, content)
    end
  end

  defp build_issue_file(story_id, issue) do
    """
    # #{issue.title}

    ## Severity

    #{issue.severity}

    ## Description

    #{issue.description}

    ## Source

    QA Story #{story_id} — `.code_my_spec/qa/#{story_id}/result.md`
    """
  end

  # ============================================================================
  # Data Loading
  # ============================================================================

  defp plan_exists?(env) do
    Environments.file_exists?(env, Paths.qa_plan())
  end

  @scripts_dir Path.join(Paths.qa_dir(), "scripts")

  defp list_scripts(env) do
    case Environments.glob(env, Path.join(@scripts_dir, "*")) do
      files when is_list(files) and files != [] -> files
      _ -> []
    end
  end

  defp collect_spec_file_paths(env, story_id) do
    specs = BddSpecs.list_specs_for_story(env, story_id)
    Enum.map(specs, & &1.file_path)
  end

  # ============================================================================
  # Prompt File (written to disk)
  # ============================================================================

  defp build_prompt_file(story, spec_paths) do
    criteria_text = format_criteria(Map.get(story, :criteria, []))
    specs_text = format_spec_paths(spec_paths)

    """
    # Story #{story.id}: #{story.title}

    ## Description

    #{story.description || "_No description._"}

    ## Acceptance Criteria

    #{criteria_text}

    ## BDD Spec Files

    #{specs_text}

    ## Testing Approach

    - Navigate the feature and capture a screenshot at each key state (initial load, after interactions, success/error states)
    - After the scripted scenarios, explore freely: try unexpected inputs, edge cases, empty states, and anything that feels off
    - Save all screenshots to `.code_my_spec/qa/#{story.id}/screenshots/` — they are evidence and must be committed
    """
  end

  # ============================================================================
  # Agent Prompt (returned to caller)
  # ============================================================================

  defp build_agent_prompt(story_id, prompt_path, brief_path, plan_exists, existing_scripts, brief_spec) do
    sections =
      [
        build_header(story_id),
        build_brief_spec_section(brief_spec),
        build_plan_reference(plan_exists),
        build_scripts_section(existing_scripts),
        build_prompt_reference(prompt_path),
        build_instructions(story_id, prompt_path, brief_path)
      ]
      |> Enum.reject(&is_nil/1)

    Enum.join(sections, "\n\n")
  end

  defp build_header(story_id) do
    """
    # QA Story: Plan and Test Story #{story_id}

    You are the QA agent for story #{story_id}. Your first task is to plan the
    testing approach by writing a brief. Stop after writing the brief so it can
    be validated before you test.

    Read `#{Paths.framework_dir()}/qa-tooling.md` for the available testing tools and patterns.
    You are a CLI agent — use the `web` tool to browse pages and shell scripts
    in `#{Paths.qa_dir()}/scripts/` for authenticated requests. You do NOT open a browser manually.
    Reference existing scripts by path rather than inlining raw curl commands.\
    """
  end

  defp build_brief_spec_section(brief_spec) do
    """
    ## Brief Format

    The brief must follow this specification:

    #{brief_spec}\
    """
  end

  defp build_plan_reference(true) do
    """
    ## QA Plan

    Read `#{Paths.qa_plan()}` for the app overview, tools registry, authentication
    strategy, and seed commands. Use this as your primary reference.\
    """
  end

  defp build_plan_reference(false) do
    """
    ## QA Plan

    **Warning:** No QA plan found at `#{Paths.qa_plan()}`. Run `qa_setup` first to
    generate the plan. Without it, you'll need to discover app details yourself.\
    """
  end

  defp build_scripts_section([]), do: nil

  defp build_scripts_section(scripts) do
    script_list = Enum.map_join(scripts, "\n", &"- `#{&1}`")

    """
    ## Available Scripts

    QaSetup created these scripts — read them and reference them in the brief's auth
    and seeds sections instead of writing inline commands:

    #{script_list}

    Run these scripts by path.\
    """
  end

  defp build_prompt_reference(prompt_path) do
    """
    ## Story Prompt

    Read `#{prompt_path}` for the story details, acceptance criteria, and BDD spec file paths.\
    """
  end

  defp build_instructions(story_id, prompt_path, brief_path) do
    """
    ## Instructions

    1. Read `#{Paths.framework_dir()}/qa-tooling.md` to understand available testing tools
    2. Read `#{prompt_path}` for story #{story_id}'s details and BDD spec file paths
    3. Read `#{Paths.qa_plan()}` for app overview, tools, auth, and seed strategy
    4. Read the BDD spec files listed in the prompt (they contain exact selectors, test data, and assertions)
    5. Write the brief to `#{brief_path}` with all required sections: tool, auth, seeds, what to test, result path

    The brief's "tool" section must specify a CLI tool (`web` for pages, `curl` for APIs,
    or a script path). You are an automated agent, not a human with a browser.

    Stop after writing the brief so it can be validated before you test.\
    """
  end

  # ============================================================================
  # Helpers
  # ============================================================================

  defp prompt_path(story_id) do
    Path.join([Paths.qa_dir(), to_string(story_id), "prompt.md"])
  end

  defp brief_path(story_id) do
    Path.join([Paths.qa_dir(), to_string(story_id), "brief.md"])
  end

  defp result_path(story_id) do
    Path.join([Paths.qa_dir(), to_string(story_id), "result.md"])
  end

  defp format_criteria(nil), do: "_None defined._"
  defp format_criteria([]), do: "_None defined._"

  defp format_criteria(criteria) do
    Enum.map_join(criteria, "\n", fn c -> "- #{c.description}" end)
  end

  defp format_spec_paths([]), do: "_No BDD specs found. Read the router and app code to understand this story's scope._"

  defp format_spec_paths(paths) do
    Enum.map_join(paths, "\n", &"- `#{&1}`")
  end
end
