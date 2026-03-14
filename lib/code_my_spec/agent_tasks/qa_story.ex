defmodule CodeMySpec.AgentTasks.QaStory do
  @moduledoc """
  Per-story QA agent that plans and tests a single user story.

  Takes a story ID from `session.state["topic"]`.

  Evaluate is a state machine — phase is derived from artifact existence:
  1. **plan** — plan.md missing/invalid → feedback
  2. **brief** — brief.md missing or invalid → feedback to write the brief
  3. **test** — brief valid, result.md missing or invalid → feedback to test
  4. **done** — all valid → file issues, return :valid

  Three artifacts for inspectability:
  - `brief.md` — agent's plan of attack (written by the agent)
  - `result.md` — test outcomes with evidence (written by the agent)

  Three main functions:
  - `command/3` — Returns the full prompt (no file writes)
  - `orchestrate/3` — Writes prompt to file, returns QA-specific orchestration for the main agent
  - `evaluate/3` — State machine: validates plan → brief → result → files issues
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
  Build the phase-appropriate QA prompt for a story.

  Phase-aware: checks current state and returns a self-contained prompt
  for the current step only. Does not write any files.

  - No plan → plan-phase prompt (write the QA plan)
  - No brief → brief-phase prompt (write the brief)
  - Brief exists → test-phase prompt (execute tests, write result)

  Returns `{:ok, prompt_text}`
  """
  def command(scope, session, _opts \\ []) do
    with {:ok, story_id} <- get_story_id(session) do
      env = scope.environment
      story = Stories.get_story!(scope, story_id)
      ensure_qa_dirs(env, story_id)

      prompt =
        with :ok <- plan_or_prompt(env, scope, story),
             :ok <- brief_or_prompt(env, scope, story) do
          build_test_phase_prompt(scope, story_id)
        end

      {:ok, prompt}
    end
  end

  # ============================================================================
  # Evaluate — state machine
  # ============================================================================

  @doc """
  State machine evaluate — phase is derived from artifact existence.

  Phase flow:
  1. plan.md missing/invalid → feedback
  2. brief.md missing/invalid → feedback to write the brief
  3. brief valid, result.md missing/invalid → feedback to execute tests
  4. all valid → file issues, return :valid

  Returns:
  - `{:ok, :valid}` when all phases pass (issues filed)
  - `{:ok, :invalid, feedback}` when the current phase artifact is missing or invalid
  """
  def evaluate(scope, session, _opts \\ []) do
    with {:ok, story_id} <- get_story_id(session) do
      env = scope.environment
      Logger.info("[QaStory] evaluate: story_id=#{story_id}")

      with :ok <- check_plan(env),
           :ok <- check_brief(env, story_id),
           {:ok, document} <- check_result(env, story_id),
           :ok <- ensure_issues_filed(scope, story_id, document) do
        Logger.info("[QaStory] evaluate: all phases valid, issues filed")
        {:ok, :valid}
      else
        {:ok, :invalid, feedback} = result ->
          Logger.info("[QaStory] evaluate: invalid — #{String.slice(feedback, 0..120)}")
          result
      end
    end
  end

  # ============================================================================
  # Orchestrate (used by Dispatch :orchestrate scope)
  # ============================================================================

  @tasks_dir Path.join(Paths.tasks_dir(), "qa")

  @doc """
  Orchestrate a QA story for the main agent.

  1. Checks the current phase via `run_phases/2`
  2. Writes the phase-appropriate prompt (brief or test) to the status file
  3. Routes validation problems to a separate problems file
  4. Returns result map with QA-specific `orchestration` text

  The prompt file always reflects the current phase — when the story advances
  from brief to test phase, the prompt is rewritten with test-phase instructions.
  The problems file only contains actual validation errors.
  """
  def orchestrate(scope, session, opts \\ []) do
    with {:ok, story_id} <- get_story_id(session) do
      env = scope.environment
      tasks_dir = Keyword.get(opts, :tasks_dir, @tasks_dir)
      prompt_path = prompt_file_path(tasks_dir, story_id)
      problem_path = problem_file_path(tasks_dir, story_id)

      {complete, has_problems} =
        case run_phases(scope, story_id) do
          {:complete, _document} ->
            Environments.delete_file(env, prompt_path)
            cleanup_problem_file(env, problem_path)
            {true, false}

          {:advance, _phase} ->
            {:ok, prompt} = command(scope, session)
            :ok = Environments.write_file(env, prompt_path, prompt)
            cleanup_problem_file(env, problem_path)
            {false, false}

          {:problem, feedback} ->
            {:ok, prompt} = command(scope, session)
            :ok = Environments.write_file(env, prompt_path, prompt)
            :ok = Environments.write_file(env, problem_path, feedback)
            {false, true}
        end

      orchestration_prompt =
        build_orchestration_prompt(story_id, problem_path, complete, has_problems)

      orchestration =
        build_orchestration(story_id, prompt_path, problem_path, complete, has_problems)

      {:ok,
       %{
         prompt_path: prompt_path,
         complete: complete,
         problem_path: problem_path,
         orchestration_prompt: orchestration_prompt,
         orchestration: orchestration
       }}
    end
  end

  @doc """
  Evaluate-only counterpart to `orchestrate/3`.

  Checks completeness via `run_phases/2` and routes results:
  - **advance** — updates the prompt file with next-phase instructions, cleans problems
  - **problem** — writes validation errors to the problems file
  - **complete** — files issues, cleans up
  """
  def orchestrate_evaluate(scope, session, opts \\ []) do
    with {:ok, story_id} <- get_story_id(session) do
      env = scope.environment
      tasks_dir = Keyword.get(opts, :tasks_dir, @tasks_dir)
      prompt_path = prompt_file_path(tasks_dir, story_id)
      problem_path = problem_file_path(tasks_dir, story_id)

      Logger.info("[QaStory] orchestrate_evaluate: story_id=#{story_id}")

      {complete, has_problems} =
        case run_phases(scope, story_id) do
          {:complete, _document} ->
            Logger.info("[QaStory] orchestrate_evaluate(#{story_id}): complete, issues filed")
            Environments.delete_file(env, prompt_path)
            cleanup_problem_file(env, problem_path)
            {true, false}

          {:advance, phase} ->
            Logger.info("[QaStory] orchestrate_evaluate(#{story_id}): advancing to #{phase}")
            {:ok, prompt} = command(scope, session)
            :ok = Environments.write_file(env, prompt_path, prompt)
            cleanup_problem_file(env, problem_path)
            {false, false}

          {:problem, feedback} ->
            Logger.info("[QaStory] orchestrate_evaluate(#{story_id}): problem")
            :ok = Environments.write_file(env, problem_path, feedback)
            {false, true}
        end

      orchestration_prompt =
        build_orchestration_prompt(story_id, problem_path, complete, has_problems)

      orchestration =
        build_orchestration(story_id, prompt_path, problem_path, complete, has_problems)

      {:ok,
       %{
         complete: complete,
         problem_path: problem_path,
         orchestration_prompt: orchestration_prompt,
         orchestration: orchestration
       }}
    end
  end

  defp prompt_file_path(tasks_dir, story_id) do
    "#{tasks_dir}/story_#{story_id}_qa_story.md"
  end

  defp problem_file_path(tasks_dir, story_id) do
    "#{tasks_dir}/story_#{story_id}_qa_story_problems.md"
  end

  # Determine the current phase: complete, advancing, or has problems.
  #
  # Returns:
  # - `{:complete, document}` — all phases pass, issues filed
  # - `{:advance, phase}` — file missing for next phase → update prompt
  # - `{:problem, feedback}` — validation error in existing artifact
  defp run_phases(scope, story_id) do
    env = scope.environment

    result =
      with :ok <- check_plan(env),
           :ok <- require_file(:brief, env, brief_path(story_id)),
           :ok <- check_brief(env, story_id),
           :ok <- require_file(:test, env, result_path(story_id)),
           {:ok, document} <- check_result(env, story_id),
           :ok <- ensure_issues_filed(scope, story_id, document) do
        {:complete, document}
      else
        {:advance, _phase} = advance -> advance
        {:ok, :invalid, feedback} -> {:problem, feedback}
      end

    case result do
      {:complete, _} ->
        Logger.info("[QaStory] run_phases(#{story_id}): complete")

      {:advance, phase} ->
        Logger.info("[QaStory] run_phases(#{story_id}): advance to #{phase}")

      {:problem, feedback} ->
        Logger.info(
          "[QaStory] run_phases(#{story_id}): problem — #{String.slice(feedback, 0..120)}"
        )
    end

    result
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

  defp require_file(phase, env, path) do
    if Environments.file_exists?(env, path), do: :ok, else: {:advance, phase}
  end

  defp build_orchestration_prompt(story_id, problem_path, complete, has_problems) do
    if complete do
      "[x] QA for story #{story_id} complete."
    else
      base = "[ ] QA for story #{story_id} is not complete."
      if has_problems, do: base <> " Fix the problems at `#{problem_path}`.", else: base
    end
  end

  defp build_orchestration(story_id, prompt_path, problem_path, complete, has_problems) do
    if complete do
      """
      # QA Story #{story_id}: Complete

      All QA phases passed. Issues (if any) have been filed.
      """
    else
      problems_section =
        if has_problems do
          """

          ## Problems

          If the subagent was blocked by the validation hook, review the feedback
          at `#{problem_path}` and relay it to the subagent on its next invocation.
          """
        else
          ""
        end

      """
      # QA Story #{story_id}

      ## Prompt

      Start a codemyspec:qa subagent with exactly this prompt:
      `#{prompt_path}`

      Do NOT read the file or write instructions around it — pass the path string as-is.
      #{problems_section}
      When the subagent completes all QA phases, **stop the session** so the
      hook can validate and advance to the next task.
      """
    end
  end

  defp cleanup_problem_file(env, problem_path) do
    Environments.delete_file(env, problem_path)
    :ok
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
  # Phase Prompts — each phase is a self-contained prompt
  # ============================================================================

  # -- Plan Phase: write the QA plan -------------------------------------------

  defp build_plan_phase_prompt(scope, env, story) do
    endpoint_module = endpoint_module_name(scope)
    doc_spec = DocumentSpecProjector.project_spec("qa_plan")
    app_name = derive_app_name(env)
    router_path = "lib/#{app_name}_web/router.ex"
    scripts_dir = Path.join(Paths.qa_dir(), "scripts")
    criteria_text = format_criteria(Map.get(story, :criteria, []))

    """
    # QA Story #{story.id}: Write the QA Plan

    **App URL:** Run `mix run -e 'IO.puts(#{endpoint_module}.url())'` to get the app URL.

    No QA plan exists yet. Analyze the app and write the plan before proceeding
    to per-story testing.

    ## Story Context

    **#{story.title}** — #{story.description || "_No description._"}

    ### Acceptance Criteria

    #{criteria_text}

    ## Instructions

    1. Read `#{Paths.framework_dir()}/qa-tooling.md` for testing tool patterns and `#{Paths.framework_dir()}/qa-tooling/` for tool-specific cheat sheets
    2. Read `#{router_path}` and analyze routes, auth pipelines, and live sessions
    3. Write a standard seed script to `priv/repo/qa_seeds.exs` (`.exs` files run via `mix run`)
    4. Write additional seed scripts to `priv/repo/qa_seeds.exs` if other scenarios warrant it
    5. Write useful scripts to `#{scripts_dir}/` (`.sh` for curl wrappers, `chmod +x`)
    6. Write `#{Paths.qa_plan()}` following the format below

    Stop the session after writing the plan.

    ## QA Plan Format

    #{doc_spec}\
    """
  end

  # -- Brief Phase: write the testing brief ------------------------------------

  defp build_brief_phase_prompt(scope, env, story) do
    endpoint_module = endpoint_module_name(scope)
    spec_paths = collect_spec_file_paths(env, story.id)
    brief_spec = DocumentSpecProjector.project_spec("qa_story_brief")
    existing_scripts = list_scripts(env)
    criteria_text = format_criteria(Map.get(story, :criteria, []))
    specs_text = format_spec_paths(spec_paths)
    scripts_section = build_scripts_section(existing_scripts)
    component_section = build_component_section(scope, story)
    scripts_dir = Path.join(Paths.qa_dir(), "scripts")

    sections =
      [
        """
        # QA Story #{story.id}: Write the Brief

        **App URL:** Run `mix run -e 'IO.puts(#{endpoint_module}.url())'` to get the app URL.

        Write a testing brief for story #{story.id}. The brief tells the tester exactly
        what to do — which tools, how to authenticate, what seeds to run, and what to test.

        **Available tools:** MCP browser tools (browser automation for UI/LiveView pages), `curl` (API
        endpoint testing with API key auth), and shell scripts in `#{scripts_dir}/`.
        See `#{Paths.framework_dir()}/qa-tooling.md` for when to use each tool.

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
        ## Instructions

        1. Read `#{Paths.framework_dir()}/qa-tooling.md` for testing tool patterns and `#{Paths.framework_dir()}/qa-tooling/` for tool-specific cheat sheets
        2. Read `#{Paths.qa_plan()}` for app overview, tools, auth, and seed strategy
        3. Run seed scripts to verify setup works for this story
        4. If this story needs additional seeds, scripts, or plan updates, make them now
        5. Read the BDD spec files listed above (they contain selectors, test data, and assertions)
        6. If a linked component is listed above, read its source and spec to understand the feature
        7. Write the brief to `#{brief_path(story.id)}` following the format below

        Stop the session after writing the brief.

        ## Brief Format

        #{brief_spec}\
        """
      ]
      |> Enum.reject(&is_nil/1)

    Enum.join(sections, "\n\n")
  end

  # -- Test Phase: execute tests and write result ------------------------------

  defp build_test_phase_prompt(scope, story_id) do
    env = scope.environment
    story = Stories.get_story!(scope, story_id)
    result_spec = DocumentSpecProjector.project_spec("qa_result")
    endpoint_module = endpoint_module_name(scope)
    existing_scripts = list_scripts(env)
    screenshot_dir = screenshot_dir(story_id)
    scripts_section = build_scripts_section(existing_scripts)
    component_section = build_component_section(scope, story)

    sections =
      [
        """
        # QA Story #{story.id}: Execute Tests

        **App URL:** Run `mix run -e 'IO.puts(#{endpoint_module}.url())'` to get the app URL.

        The brief has been validated. Execute the test plan and write the result.

        Read `#{Paths.framework_dir()}/qa-tooling.md` for the available testing tools and patterns.
        You are a CLI agent — you do NOT open a browser manually.
        Reference existing scripts by path rather than inlining raw curl commands.

        **Tool rules — use the right tool for the right layer:**
        - **UI pages / LiveViews (`:browser` pipeline):** Use MCP browser tools for all interaction — navigate,
          click, type, screenshot. Log in via the browser (see the QA plan for credentials and login steps).
        - **API endpoints (`:api` pipeline):** Use `curl` with API key headers. ALWAYS single-line commands.
          Use `#{Paths.qa_dir()}/scripts/authenticated_curl.sh` for API-key-authenticated requests.
        - **NEVER** use curl with session cookies or CSRF tokens for browser-authenticated routes.
          If a route is behind `:require_authenticated_user`, test it with MCP browser tools, not curl.

        ## Story: #{story.title}

        #{story.description || "_No description._"}

        ### Testing Approach

        - Navigate the feature and capture a screenshot at each key state (initial load, after interactions, success/error states)
        - After the scripted scenarios, explore freely: try unexpected inputs, edge cases, empty states, and anything that feels off
        - Save all screenshots to `#{screenshot_dir}/` — they are evidence and must be committed\
        """,
        component_section,
        scripts_section,
        """
        ## Instructions

        1. Read the brief at `#{brief_path(story_id)}` for the complete testing plan
        2. Read `#{Paths.qa_plan()}` for auth strategy, seed commands, and login steps
        3. Read `#{Paths.framework_dir()}/qa-tooling.md` for tool usage patterns and `#{Paths.framework_dir()}/qa-tooling/` for tool-specific cheat sheets
        4. Run seed scripts to set up test data before testing
        5. If a linked component is listed above, read its source to understand the feature's implementation
        6. Execute each test scenario from the brief
        7. Capture a screenshot at each key state — save to `#{screenshot_dir}/`
        8. Attempt to resolve any issues with the plan or the QA scripts before finishing
        9. Write the result to `#{result_path(story_id)}` following the format below

        Stop the session after writing the result.

        ## Result Format

        #{result_spec}\
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

  defp plan_exists?(env) do
    Environments.file_exists?(env, Paths.qa_plan())
  end

  defp brief_exists?(env, story_id) do
    Environments.file_exists?(env, brief_path(story_id))
  end

  defp plan_or_prompt(env, scope, story) do
    if plan_exists?(env), do: :ok, else: build_plan_phase_prompt(scope, env, story)
  end

  defp brief_or_prompt(env, scope, story) do
    if brief_exists?(env, story.id), do: :ok, else: build_brief_phase_prompt(scope, env, story)
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
