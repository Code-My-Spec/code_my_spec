defmodule CodeMySpec.AgentTasks.QaStory do
  @moduledoc """
  Per-story QA agent that plans and tests a single user story.

  Takes a story ID from `task.story_id`.

  Evaluate is a state machine — phase is derived from artifact existence:
  1. **plan** — plan.md missing/invalid → feedback
  2. **brief** — brief.md missing or invalid → feedback to write the brief
  3. **test** — brief valid, result.md missing or invalid → feedback to test
  4. **done** — all valid → file issues, return :valid

  Three artifacts for inspectability:
  - `brief.md` — agent's plan of attack (written by the agent)
  - `result.md` — test outcomes with evidence (written by the agent)

  Three main functions:
  - `command/2` — Returns the full prompt (no file writes)
  - `orchestrate/3` — Writes prompt to file, returns QA-specific orchestration for the main agent
  - `evaluate/2` — State machine: validates plan → brief → result → files issues
  """

  require Logger

  alias CodeMySpec.{BddSpecs, Components, Environments, Issues, Paths, Stories}
  alias CodeMySpec.Documents
  alias CodeMySpec.Documents.DocumentSpecProjector
  alias CodeMySpec.Utils

  @required_plan_sections ["app overview", "tools registry", "seed strategy"]

  # ============================================================================
  # Command — returns the full prompt, no marker, no file writes
  # ============================================================================

  @doc """
  Build the full QA prompt for a story.

  Returns a single self-contained prompt covering all three phases
  (plan, brief, test). The agent works through them in order, skipping
  any phase whose artifact already exists.

  Returns `{:ok, prompt_text}`
  """
  def command(scope, task) do
    with {:ok, story_id} <- get_story_id(task) do
      env = scope.environment
      story = Stories.get_story!(scope, story_id)
      ensure_qa_dirs(env, story_id)
      {:ok, build_combined_prompt(scope, story)}
    end
  end

  # ============================================================================
  # Evaluate — state machine
  # ============================================================================

  @doc """
  State machine evaluate — phase is derived from artifact existence.

  Phase flow:
  1. result_complete.md exists → :valid (already passed)
  2. plan.md missing/invalid → feedback
  3. brief.md missing/invalid → feedback to write the brief
  4. result.md missing/invalid → feedback to execute tests
  5. result.md valid, status=pass → file issues, move to result_complete.md → :valid
  6. result.md valid, status=fail/partial → file issues, archive as result_failed_{ts}.md → :invalid

  Returns:
  - `{:ok, :valid}` when QA passed (result_complete.md exists)
  - `{:ok, :invalid, feedback}` when the current phase artifact is missing or invalid
  """
  def evaluate(scope, task) do
    with {:ok, story_id} <- get_story_id(task) do
      env = scope.environment
      Logger.info("[QaStory] evaluate: story_id=#{story_id}")

      # Short-circuit: already completed
      if Environments.file_exists?(env, result_complete_path(story_id)) do
        Logger.info("[QaStory] evaluate: result_complete.md exists, already passed")
        {:ok, :valid}
      else
        do_evaluate(scope, env, story_id)
      end
    end
  end

  defp do_evaluate(scope, env, story_id) do
    with :ok <- check_plan(env),
         :ok <- check_brief(env, story_id),
         {:ok, document} <- check_result(env, story_id) do
      finalize_result(scope, env, story_id, document)
    else
      {:ok, :invalid, feedback} = result ->
        Logger.info("[QaStory] evaluate: invalid — #{String.slice(feedback, 0..120)}")
        result
    end
  end

  # After result.md is structurally valid, check pass/fail status and finalize.
  defp finalize_result(scope, env, story_id, document) do
    # Always file issues regardless of pass/fail
    ensure_issues_filed(scope, story_id, document)

    if qa_passed?(document) do
      Logger.info("[QaStory] evaluate(#{story_id}): QA passed — promoting to result_complete.md")
      move_file(env, result_path(story_id), result_complete_path(story_id))
    else
      timestamp = DateTime.utc_now() |> Calendar.strftime("%Y%m%d_%H%M%S")
      failed_path = result_failed_path(story_id, timestamp)
      Logger.info("[QaStory] evaluate(#{story_id}): QA failed — archiving to #{failed_path}, issues filed for triage")
      move_file(env, result_path(story_id), failed_path)
    end

    # Always return :valid — let the QA session complete.
    # StoryQaChecker checks for result_complete.md, so the story requirement
    # stays unsatisfied until QA actually passes. Failed results get picked
    # up on the next triage cycle.
    {:ok, :valid}
  end

  defp qa_passed?(document) do
    status =
      document.sections
      |> Map.get("status", "")
      |> to_string()
      |> String.downcase()
      |> String.trim()

    status in ["pass", "passed"]
  end

  defp move_file(env, from, to) do
    case Environments.read_file(env, from) do
      {:ok, content} ->
        Environments.write_file(env, to, content)
        Environments.delete_file(env, from)

      {:error, _} ->
        :ok
    end
  end

  # ============================================================================
  # Orchestrate (used by graph dispatcher)
  # ============================================================================

  def orchestrate(node) do
    "Spawn a @qa sub-agent to call `start_task` with requirement `#{node.name}` for #{node.entity_type} `#{node.entity_id}` (#{node.entity_name})"
  end

  # File issues from the QA result to the database and verify they're persisted.
  # This phase ensures issues are created in the DB and projected to disk
  # before qa_complete can be marked as satisfied.
  defp ensure_issues_filed(scope, story_id, document) do
    {:ok, created} = Issues.create_from_qa_result(scope, story_id, document)
    issues_in_result = Map.get(document.sections, "issues", [])

    if issues_in_result == [] or issues_in_result == "None" do
      Logger.info("[QaStory] ensure_issues_filed(#{story_id}): no issues to file")
      :ok
    else
      Logger.info(
        "[QaStory] ensure_issues_filed(#{story_id}): #{length(created)} issues filed"
      )

      :ok
    end
  end

  # ============================================================================
  # Session Helpers
  # ============================================================================

  defp get_story_id(%{story_id: story_id}) when not is_nil(story_id) do
    case Integer.parse(to_string(story_id)) do
      {id, _} -> {:ok, id}
      :error -> {:error, "QaStory requires a numeric story ID, got: #{inspect(story_id)}"}
    end
  end

  defp get_story_id(_task) do
    {:error, "QaStory requires a story ID argument. Usage: /qa-story <story_id>"}
  end

  # ============================================================================
  # Phase Checks
  # ============================================================================

  defp check_plan(env) do
    case Environments.read_file(env, Paths.qa_plan()) do
      {:ok, content} when is_binary(content) and byte_size(content) > 0 ->
        validate_plan_sections(content)

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
        screenshot_dir = screenshot_dir(story_id)

        {:ok, :invalid,
         "Brief validated. Now execute the test plan from the brief and write the result to `#{path}`. " <>
           "Save screenshots to `#{screenshot_dir}/`. " <>
           "Stop the session when done.\n\n## Result Format\n\n" <>
           result_spec}
    end
  end

  # ============================================================================
  # Combined Prompt — all three phases in one
  # ============================================================================

  defp build_combined_prompt(scope, story) do
    env = scope.environment
    story_id = story.id
    endpoint_module = endpoint_module_name(scope)
    app_name = derive_app_name(env)
    router_path = "lib/#{app_name}_web/router.ex"
    scripts_dir = Path.join(Paths.qa_dir(), "scripts")
    criteria_text = format_criteria(Map.get(story, :criteria, []))
    spec_paths = collect_spec_file_paths(env, story_id)
    specs_text = format_spec_paths(spec_paths)
    existing_scripts = list_scripts(env)
    scripts_section = build_scripts_section(existing_scripts)
    component_section = build_component_section(scope, story)
    plan_spec = DocumentSpecProjector.project_spec("qa_plan")
    brief_spec = DocumentSpecProjector.project_spec("qa_story_brief")
    result_spec = DocumentSpecProjector.project_spec("qa_result")
    screenshot_dir = screenshot_dir(story_id)

    sections =
      [
        """
        # QA Story #{story_id}: Complete QA Session

        **App URL:** Run `mix run -e 'IO.puts(#{endpoint_module}.url())'` to get the app URL.

        Complete all three QA phases for this story in order. Each phase produces
        an artifact — write each one before moving to the next. If an artifact
        already exists, skip that phase.

        ## Story: #{story.title}

        #{story.description || "_No description._"}

        ### Acceptance Criteria

        #{criteria_text}

        ### BDD Spec Files

        #{specs_text}\
        """,
        component_section,
        scripts_section,
        """
        ## Phase 1: QA Plan

        **Artifact:** `#{Paths.qa_plan()}`

        If the plan already exists with all required sections (App Overview,
        Tools Registry, Seed Strategy), skip to Phase 2.

        Otherwise:
        1. Read `qa-tooling.md` (call `read_knowledge` MCP tool with `path: "qa-tooling.md"`) for testing tool patterns and `qa-tooling/` (call `list_knowledge` MCP tool with `path: "qa-tooling"`) for tool-specific cheat sheets
        2. Read `#{router_path}` and analyze routes, auth pipelines, and live sessions
        3. Write a standard seed script to `priv/repo/qa_seeds.exs` (`.exs` files run via `mix run`)
        4. Write additional seed scripts if other scenarios warrant it
        5. Write useful scripts to `#{scripts_dir}/` (`.sh` for curl wrappers, `chmod +x`)
        6. Write `#{Paths.qa_plan()}` following this format:

        #{plan_spec}

        ## Phase 2: Testing Brief

        **Artifact:** `#{brief_path(story_id)}`

        Write a testing brief that tells the tester exactly what to do — which tools,
        how to authenticate, what seeds to run, and what to test.

        **Available tools:** MCP browser tools (browser automation for UI/LiveView pages), `curl` (API
        endpoint testing with API key auth), and shell scripts in `#{scripts_dir}/`.
        See `qa-tooling.md` (call `read_knowledge` MCP tool with `path: "qa-tooling.md"`) for when to use each tool.

        1. Read `#{Paths.qa_plan()}` for app overview, tools, auth, and seed strategy
        2. Run seed scripts to verify setup works for this story
        3. If this story needs additional seeds, scripts, or plan updates, make them now
        4. Read the BDD spec files listed above (they contain selectors, test data, and assertions)
        5. If a linked component is listed above, read its source and spec to understand the feature
        6. Write the brief to `#{brief_path(story_id)}` following this format:

        #{brief_spec}

        ## Phase 3: Execute Tests

        **Artifact:** `#{result_path(story_id)}`

        Execute the test plan from the brief and write the result.

        You are a CLI agent — you do NOT open a browser manually.
        Reference existing scripts by path rather than inlining raw curl commands.

        **Tool rules — use the right tool for the right layer:**
        - **UI pages / LiveViews (`:browser` pipeline):** Use MCP browser tools for all interaction — navigate,
          click, type, screenshot. Log in via the browser (see the QA plan for credentials and login steps).
        - **API endpoints (`:api` pipeline):** Use `curl` with API key headers. ALWAYS single-line commands.
          Use `#{Paths.qa_dir()}/scripts/authenticated_curl.sh` for API-key-authenticated requests.
        - **NEVER** use curl with session cookies or CSRF tokens for browser-authenticated routes.
          If a route is behind `:require_authenticated_user`, test it with MCP browser tools, not curl.

        ### Testing Approach

        - Navigate the feature and capture a screenshot at each key state (initial load, after interactions, success/error states)
        - After the scripted scenarios, explore freely: try unexpected inputs, edge cases, empty states, and anything that feels off
        - Save all screenshots to `#{screenshot_dir}/` — they are evidence and must be committed

        ### Instructions

        1. Read the brief at `#{brief_path(story_id)}` for the complete testing plan
        2. Read `#{Paths.qa_plan()}` for auth strategy, seed commands, and login steps
        3. Read `qa-tooling.md` (call `read_knowledge` MCP tool with `path: "qa-tooling.md"`) for tool usage patterns and `qa-tooling/` (call `list_knowledge` MCP tool with `path: "qa-tooling"`) for tool-specific cheat sheets
        4. Run seed scripts to set up test data before testing
        5. If a linked component is listed above, read its source to understand the feature's implementation
        6. Execute each test scenario from the brief
        7. Capture a screenshot at each key state — save to `#{screenshot_dir}/`
        8. Attempt to resolve any issues with the plan or the QA scripts before finishing
        9. Write the result to `#{result_path(story_id)}` following this format:

        #{result_spec}

        Stop the session after writing the result.\
        """
      ]
      |> Enum.reject(&is_nil/1)

    Enum.join(sections, "\n\n")
  end

  # -- Shared prompt helpers ---------------------------------------------------

  defp build_scripts_section([]), do: nil

  defp build_scripts_section(scripts) do
    script_list = Enum.map_join(scripts, "\n", &"- `#{&1}`")

    """
    ## Available Scripts

    These scripts handle auth and seeds — reference them in the brief instead
    of writing inline commands:

    #{script_list}\
    """
  end

  defp build_component_section(scope, story) do
    case story.component_id do
      nil ->
        nil

      component_id ->
        try do
          component = Components.get_component!(scope, component_id)
          files = Utils.component_files(component, scope.active_project)
          file_list = format_component_files(files)

          """
          ## Linked Component: #{component.name}

          This story is implemented by `#{component.module_name}` (#{component.type}).
          Reading the source code and spec will help you understand what to test
          and how the feature works.

          #{file_list}\
          """
        rescue
          _ -> nil
        end
    end
  end

  defp format_component_files(files) do
    files
    |> Enum.map(fn
      {:spec_file, path} -> "- Spec: `#{path}`"
      {:code_file, path} -> "- Source: `#{path}`"
      {:test_file, path} -> "- Tests: `#{path}`"
      _ -> nil
    end)
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
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
  # Path Helpers
  # ============================================================================

  defp brief_path(story_id) do
    Path.join([Paths.qa_dir(), to_string(story_id), "brief.md"])
  end

  defp result_path(story_id) do
    Path.join([Paths.qa_dir(), to_string(story_id), "result.md"])
  end

  defp result_complete_path(story_id) do
    Path.join([Paths.qa_dir(), to_string(story_id), "result_complete.md"])
  end

  defp result_failed_path(story_id, timestamp) do
    Path.join([Paths.qa_dir(), to_string(story_id), "result_failed_#{timestamp}.md"])
  end

  defp screenshot_dir(story_id) do
    Path.join([Paths.qa_dir(), to_string(story_id), "screenshots"])
  end

  defp ensure_qa_dirs(env, story_id) do
    Environments.ensure_dir(env, screenshot_dir(story_id))
    :ok
  end

  # ============================================================================
  # Formatting Helpers
  # ============================================================================

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
