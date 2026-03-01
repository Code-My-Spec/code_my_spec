defmodule CodeMySpec.AgentTasks.QaStory do
  @moduledoc """
  Per-story QA agent that plans and tests a single user story.

  Takes a story ID from `session.state["topic"]`, writes
  `.code_my_spec/qa/{story_id}/prompt.md` with story metadata and BDD spec paths,
  then returns a prompt telling the agent to write a brief and stop.

  Evaluate is a state machine — phase is derived from artifact existence:
  1. **plan** — plan.md missing/invalid or plan_updates.md pending → feedback
  2. **brief** — brief.md missing or invalid → feedback to write the brief
  3. **test** — brief valid, result.md missing or invalid → feedback to test
  4. **done** — all valid → file issues, write plan_updates.md, return :valid

  Three artifacts for inspectability:
  - `prompt.md` — story context (written by this code)
  - `brief.md` — agent's plan of attack (written by the agent)
  - `result.md` — test outcomes with evidence (written by the agent)

  Plan lifecycle:
  - `plan.md` — shared QA plan (written by agent, validated by evaluate)
  - `plan_updates.md` — accumulated findings from testing (written by evaluate, incorporated by next agent)

  Two main functions:
  - `command/3` — Writes prompt.md to disk, returns agent prompt (phase 1 only)
  - `evaluate/3` — State machine: validates plan → brief → result → files issues → writes updates
  """

  require Logger

  alias CodeMySpec.AgentTasks.TaskMarker
  alias CodeMySpec.{BddSpecs, Environments, Paths, Stories}
  alias CodeMySpec.Documents
  alias CodeMySpec.Documents.{DocumentSpecProjector, QaIssue}

  @required_plan_sections ["app overview", "tools registry", "seed strategy"]

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
      endpoint_module = endpoint_module_name(scope)

      story = Stories.get_story!(scope, story_id)
      spec_paths = collect_spec_file_paths(env, story_id)
      prompt_path = prompt_path(story_id)
      brief_path = brief_path(story_id)

      # Write the prompt file to disk as shared context
      prompt_content = build_prompt_file(story, spec_paths, endpoint_module)
      Environments.write_file(env, prompt_path, prompt_content)

      # Return agent prompt pointing to the files
      existing_scripts = list_scripts(env)
      brief_spec = DocumentSpecProjector.project_spec("qa_story_brief")

      agent_prompt =
        build_agent_prompt(
          story_id,
          prompt_path,
          brief_path,
          env,
          existing_scripts,
          brief_spec,
          endpoint_module
        )

      {:ok, TaskMarker.build("QaStory", to_string(story_id)) <> "\n\n" <> agent_prompt}
    end
  end

  @doc """
  State machine evaluate — phase is derived from artifact existence.

  Phase flow:
  1. plan.md missing/invalid or plan_updates.md pending → feedback
  2. brief.md missing/invalid → feedback to write the brief
  3. brief valid, result.md missing/invalid → feedback to execute tests
  4. all valid → file issues, write plan_updates.md, return :valid

  Returns:
  - `{:ok, :valid}` when all phases pass (issues filed, plan updates written)
  - `{:ok, :invalid, feedback}` when the current phase artifact is missing or invalid
  """
  def evaluate(scope, session, _opts \\ []) do
    with {:ok, story_id} <- get_story_id(session) do
      env = scope.environment

      with :ok <- check_plan(env),
           :ok <- check_brief(env, story_id),
           {:ok, document} <- check_result(env, story_id) do
        create_issue_files(env, story_id, document)
        write_plan_updates(env, story_id, document)
        {:ok, :valid}
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

  defp check_plan(env) do
    case Environments.read_file(env, Paths.qa_plan()) do
      {:ok, content} when is_binary(content) and byte_size(content) > 0 ->
        with :ok <- validate_plan_sections(content) do
          check_plan_updates(env)
        end

      _ ->
        doc_spec = DocumentSpecProjector.project_spec("qa_plan")

        {:ok, :invalid,
         "QA plan not found at `#{Paths.qa_plan()}`. " <>
           "Write the QA plan before continuing with the story brief.\n\n" <>
           "## QA Plan Format\n\n#{doc_spec}"}
    end
  end

  defp validate_plan_sections(content) do
    content_lower = String.downcase(content)

    missing =
      Enum.reject(@required_plan_sections, fn section ->
        String.contains?(content_lower, "## #{section}")
      end)

    case missing do
      [] ->
        :ok

      sections ->
        section_list = Enum.map_join(sections, ", ", &"`## #{title_case(&1)}`")
        doc_spec = DocumentSpecProjector.project_spec("qa_plan")

        {:ok, :invalid,
         "QA plan at `#{Paths.qa_plan()}` is missing required section(s): #{section_list}. " <>
           "Update the plan and stop the session again.\n\n## QA Plan Format\n\n#{doc_spec}"}
    end
  end

  defp check_plan_updates(env) do
    path = plan_updates_path()

    case Environments.read_file(env, path) do
      {:ok, content} when is_binary(content) and byte_size(content) > 0 ->
        {:ok, :invalid,
         "Plan updates are pending at `#{path}`. Incorporate these findings " <>
           "into `#{Paths.qa_plan()}` and delete `#{path}` when done. " <>
           "Stop the session after updating.\n\n#{content}"}

      _ ->
        :ok
    end
  end

  defp check_brief(env, story_id) do
    path = brief_path(story_id)

    case Environments.read_file(env, path) do
      {:ok, content} when is_binary(content) and byte_size(content) > 0 ->
        case Documents.create_dynamic_document(content, "qa_story_brief") do
          {:ok, _document} ->
            :ok

          {:error, reason} ->
            {:ok, :invalid,
             "Brief at `#{path}` is invalid: #{reason}. Fix the brief and stop the session again."}
        end

      _ ->
        {:ok, :invalid,
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
            {:ok, document}

          {:error, reason} ->
            {:ok, :invalid,
             "Brief validated. Result at `#{path}` is invalid: #{reason}. " <>
               "Fix the result to match this specification and stop the session.\n\n" <>
               result_spec}
        end

      _ ->
        screenshot_dir = Path.join([Paths.qa_dir(), to_string(story_id), "screenshots"])

        {:ok, :invalid,
         "Brief validated. Now execute the test plan from the brief and write the result to `#{path}`. " <>
           "Save screenshots to `#{screenshot_dir}/`. " <>
           "Stop the session when done.\n\n## Result Format\n\n" <>
           result_spec}
    end
  end

  defp write_plan_updates(env, story_id, document) do
    issues = Map.get(document.sections, "issues", [])
    fileable = if is_list(issues), do: Enum.filter(issues, &QaIssue.fileable?/1), else: []

    path = plan_updates_path()

    existing =
      case Environments.read_file(env, path) do
        {:ok, content} when is_binary(content) and byte_size(content) > 0 -> content
        _ -> "# QA Plan Updates\n\nFindings from per-story QA testing to incorporate into the plan.\n"
      end

    entry = build_plan_update_entry(story_id, fileable)
    Environments.write_file(env, path, existing <> "\n" <> entry)
  end

  defp build_plan_update_entry(story_id, []) do
    "## Story #{story_id}\n\nNo issues found.\n"
  end

  defp build_plan_update_entry(story_id, issues) do
    issue_list = Enum.map_join(issues, "\n", &"- **#{&1.severity}**: #{&1.title}")
    "## Story #{story_id}\n\n#{issue_list}\n"
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

    path = Path.join(Paths.issues_incoming_dir(), "qa-#{story_id}-#{slug}.md")

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

  defp endpoint_module_name(scope) do
    case scope.active_project do
      %{module_name: name} when is_binary(name) and name != "" ->
        "#{name}Web.Endpoint"

      _ ->
        "MyAppWeb.Endpoint"
    end
  end

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

  defp build_prompt_file(story, spec_paths, endpoint_module) do
    criteria_text = format_criteria(Map.get(story, :criteria, []))
    specs_text = format_spec_paths(spec_paths)

    """
    # Story #{story.id}: #{story.title}

    ## App URL

    Run `mix run -e 'IO.puts(#{endpoint_module}.url())'` to get the app URL.

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

  defp build_agent_prompt(
         story_id,
         prompt_path,
         brief_path,
         env,
         existing_scripts,
         brief_spec,
         endpoint_module
       ) do
    sections =
      [
        build_header(story_id, endpoint_module),
        build_brief_spec_section(brief_spec),
        build_plan_reference(env),
        build_scripts_section(existing_scripts),
        build_prompt_reference(prompt_path),
        build_instructions(story_id, prompt_path, brief_path)
      ]
      |> Enum.reject(&is_nil/1)

    Enum.join(sections, "\n\n")
  end

  defp build_header(story_id, endpoint_module) do
    """
    # QA Story: Plan and Test Story #{story_id}

    **App URL:** Run `mix run -e 'IO.puts(#{endpoint_module}.url())'` to get the app URL.

    You are the QA agent for story #{story_id}. Your first task is to plan the
    testing approach by writing a brief. Stop after writing the brief so it can
    be validated before you test.

    Read `#{Paths.framework_dir()}/qa-tooling.md` for the available testing tools and patterns.
    You are a CLI agent — use `vibium` for browser automation (navigate, click, type,
    screenshot) and shell scripts in `#{Paths.qa_dir()}/scripts/` for authenticated requests.
    You do NOT open a browser manually.
    Reference existing scripts by path rather than inlining raw curl commands.

    **Tool rules:**
    - **Browser testing:** Use `vibium` commands (`vibium navigate`, `vibium click`, `vibium type`,
      `vibium screenshot`, etc.).
    - **API testing:** Use `curl` but ALWAYS write single-line commands. Multi-line curl commands
      (with backslash continuations) require individual approval and block the session.\
    """
  end

  defp build_brief_spec_section(brief_spec) do
    """
    ## Brief Format

    The brief must follow this specification:

    #{brief_spec}\
    """
  end

  defp build_plan_reference(env) do
    if plan_exists?(env) do
      updates_path = plan_updates_path()

      if Environments.file_exists?(env, updates_path) do
        """
        ## QA Plan

        Read `#{Paths.qa_plan()}` for the app overview, tools registry, authentication
        strategy, and seed commands.

        **Plan updates pending at `#{updates_path}`.** Read the updates from previous
        story testing and incorporate relevant findings into the plan. Delete
        `#{updates_path}` when done.\
        """
      else
        """
        ## QA Plan

        Read `#{Paths.qa_plan()}` for the app overview, tools registry, authentication
        strategy, and seed commands. Use this as your primary reference.\
        """
      end
    else
      doc_spec = DocumentSpecProjector.project_spec("qa_plan")
      app_name = derive_app_name(env)
      router_content = read_router(env, app_name)
      router_section = build_setup_router_section(router_content)
      scripts_dir = Path.join(Paths.qa_dir(), "scripts")

      """
      ## QA Plan

      **No QA plan found at `#{Paths.qa_plan()}`.**

      Before writing the brief, set up QA infrastructure:

      #{router_section}

      ### Setup Steps

      1. Read `#{Paths.framework_dir()}/qa-tooling.md` for testing tool patterns
      2. Analyze the router for routes, auth pipelines, and live sessions
      3. Write seed scripts to `priv/repo/qa_seeds.exs` (`.exs` files run via `mix run`)
      4. Write auth scripts to `#{scripts_dir}/` (`.sh` for curl wrappers, `chmod +x`)
      5. Write `#{Paths.qa_plan()}` following this specification:

      #{doc_spec}\
      """
    end
  end

  defp build_setup_router_section(nil) do
    "Run `mix phx.routes` to discover available routes."
  end

  defp build_setup_router_section(router_content) do
    """
    ### Router

    ```elixir
    #{router_content}
    ```\
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

    The brief's "tool" section must specify a CLI tool (`vibium` for browser testing, `curl` for APIs,
    or a script path). You are an automated agent, not a human with a browser.
    NEVER use the `web` tool — use `vibium` instead. All curl commands MUST be single-line.

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

  defp plan_updates_path do
    Path.join(Paths.qa_dir(), "plan_updates.md")
  end

  defp format_criteria(nil), do: "_None defined._"
  defp format_criteria([]), do: "_None defined._"

  defp format_criteria(criteria) do
    Enum.map_join(criteria, "\n", fn c -> "- #{c.description}" end)
  end

  defp format_spec_paths([]),
    do: "_No BDD specs found. Read the router and app code to understand this story's scope._"

  defp format_spec_paths(paths) do
    Enum.map_join(paths, "\n", &"- `#{&1}`")
  end

  defp title_case(string) do
    string
    |> String.split(" ")
    |> Enum.map_join(" ", &String.capitalize/1)
  end
end
