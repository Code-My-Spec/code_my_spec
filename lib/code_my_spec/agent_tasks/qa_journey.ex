defmodule CodeMySpec.AgentTasks.QaJourney do
  @moduledoc """
  Plans, executes, and codifies end-to-end QA journeys.

  Three requirements point at this module (plan → execute → wallaby), each
  with a `:path_exists` check in RequirementCalculator. No custom evaluate —
  the combined prompt tells the agent to skip phases whose artifacts exist.

  Artifacts:
  - `.code_my_spec/qa/journey_plan.md`
  - `.code_my_spec/qa/journey_result.md`
  - `test/journeys/*_test.exs`
  """

  alias CodeMySpec.Documents.DocumentSpecProjector
  alias CodeMySpec.{Environments, Paths, Stories}

  @stories_file Path.join(Paths.qa_dir(), "stories_summary.md")
  @wallaby_dir Paths.qa_journey_wallaby_dir()

  def orchestrate(node) do
    "Call `start_task` with requirement `#{node.name}` for #{node.entity_type} `#{node.entity_id}` (#{node.entity_name})"
  end

  @doc """
  Build the combined QA journey prompt covering all three phases.

  Returns `{:ok, prompt_text}`
  """
  def command(scope, _task) do
    env = scope.environment

    stories = list_stories(scope)
    plan_spec = DocumentSpecProjector.project_spec("qa_journey_plan")
    result_spec = DocumentSpecProjector.project_spec("qa_journey_result")

    qa_plan_exists = Environments.file_exists?(env, Paths.qa_plan()) == true
    journey_plan_exists = Environments.file_exists?(env, Paths.qa_journey_plan()) == true
    journey_result_exists = Environments.file_exists?(env, Paths.qa_journey_result()) == true
    existing_wallaby = list_wallaby_tests(env)
    architecture_path = Path.join(Paths.architecture_dir(), "overview.md")
    architecture_exists = Environments.file_exists?(env, architecture_path) == true

    stories_file_written = write_stories_file(env, stories)

    prompt =
      build_prompt(%{
        stories: stories,
        plan_spec: plan_spec,
        result_spec: result_spec,
        qa_plan_exists: qa_plan_exists,
        journey_plan_exists: journey_plan_exists,
        journey_result_exists: journey_result_exists,
        existing_wallaby: existing_wallaby,
        architecture_exists: architecture_exists,
        architecture_path: architecture_path,
        stories_file_written: stories_file_written,
        cwd: env.cwd
      })

    {:ok, prompt}
  end

  # ============================================================================
  # Data Loading
  # ============================================================================

  defp list_stories(scope) do
    Stories.list_stories(scope)
  rescue
    _ -> []
  end

  defp list_wallaby_tests(env) do
    case Environments.glob(env, Path.join(@wallaby_dir, "*_test.exs")) do
      files when is_list(files) and files != [] -> files
      _ -> []
    end
  end

  defp write_stories_file(_env, []), do: false

  defp write_stories_file(env, stories) do
    content =
      Enum.map_join(stories, "\n\n", fn story ->
        criteria_text = format_criteria(Map.get(story, :criteria, []))

        """
        ## Story #{story.id} — #{story.title}

        #{story.description || "(no description)"}

        #{criteria_text}\
        """
      end)

    case Environments.write_file(env, @stories_file, "# Stories\n\n" <> content) do
      :ok -> true
      _ -> false
    end
  end

  defp format_criteria([]), do: "_No acceptance criteria._"

  defp format_criteria(criteria) do
    Enum.map_join(criteria, "\n", fn c -> "- #{c.description}" end)
  end

  defp read_file(env, path) do
    case Environments.read_file(env, path) do
      {:ok, content} when byte_size(content) > 0 -> content
      _ -> nil
    end
  end

  # ============================================================================
  # Prompt Building
  # ============================================================================

  defp build_prompt(ctx) do
    sections =
      [
        build_header(),
        build_context_section(ctx),
        build_stories_section(ctx.stories, ctx.stories_file_written),
        build_phase_1(ctx),
        build_phase_2(ctx),
        build_phase_3(ctx)
      ]
      |> Enum.reject(&is_nil/1)

    Enum.join(sections, "\n\n")
  end

  defp build_header do
    """
    # QA Journey: Complete Pipeline

    Complete all three QA journey phases in order. Each phase produces an
    artifact — write each one before moving to the next. If an artifact
    already exists, skip that phase.\
    """
  end

  defp build_context_section(ctx) do
    read_items =
      [
        if(ctx.qa_plan_exists,
          do: "- `#{Paths.qa_plan()}` — QA infrastructure (tools, auth, seeds)"
        ),
        if(ctx.architecture_exists,
          do: "- `#{ctx.architecture_path}` — system component graph and dependencies"
        ),
        if(ctx.journey_plan_exists,
          do: "- `#{Paths.qa_journey_plan()}` — existing journey plan"
        ),
        if(ctx.journey_result_exists,
          do: "- `#{Paths.qa_journey_result()}` — existing journey result"
        )
      ]
      |> Enum.reject(&is_nil/1)

    case read_items do
      [] ->
        """
        ## Context

        No QA plan or architecture overview found. Read the app's router and config
        directly to understand routes, auth, and available features.\
        """

      items ->
        """
        ## Context

        Read these files to understand the app before designing journeys:

        #{Enum.join(items, "\n")}\
        """
    end
  end

  defp build_stories_section([], _stories_file_written) do
    """
    ## Stories

    No stories found. Design journeys based on the app's routes and features.\
    """
  end

  defp build_stories_section(stories, stories_file_written) do
    story_list =
      Enum.map_join(stories, "\n", fn story ->
        "- Story #{story.id} — #{story.title}"
      end)

    detail_note =
      if stories_file_written,
        do: "\n\nFull descriptions and acceptance criteria: `#{@stories_file}`",
        else: ""

    """
    ## Stories

    #{story_list}#{detail_note}\
    """
  end

  # -- Phase 1: Journey Planning -----------------------------------------------

  defp build_phase_1(%{journey_plan_exists: true}) do
    """
    ## Phase 1: Journey Planning — SKIP

    Journey plan already exists at `#{Paths.qa_journey_plan()}`. Proceed to Phase 2.\
    """
  end

  defp build_phase_1(%{plan_spec: plan_spec}) do
    """
    ## Phase 1: Journey Planning

    **Artifact:** `#{Paths.qa_journey_plan()}`

    Design end-to-end QA journeys for this application. Each journey traces a complete
    user path — setup, authentication, core workflows, verification. Journeys test the
    app holistically, not story-by-story.

    ### Steps

    1. Read the context files listed above
    2. Design 3-5 end-to-end journeys covering the app's core workflows
    3. Each journey: name, user role, numbered steps, expected outcome
    4. Include a prerequisites section (server startup, seeds, credentials)
    5. Write to `#{Paths.qa_journey_plan()}` following this format:

    #{plan_spec}\
    """
  end

  # -- Phase 2: Journey Execution -----------------------------------------------

  defp build_phase_2(%{journey_result_exists: true}) do
    """
    ## Phase 2: Journey Execution — SKIP

    Journey result already exists at `#{Paths.qa_journey_result()}`. Proceed to Phase 3.\
    """
  end

  defp build_phase_2(ctx) do
    server_note = """
    Before testing, ensure the Phoenix server is running:

    1. Check if the server is listening: `lsof -i -P -n | grep LISTEN`
    2. If not running, start it: `cd #{ctx.cwd} && mix phx.server &`
    3. Verify with browser tools against the app URL\
    """

    qa_plan_note =
      if ctx.qa_plan_exists,
        do:
          "Reference `#{Paths.qa_plan()}` for QA infrastructure (tools, auth, seed strategy).",
        else: ""

    """
    ## Phase 2: Journey Execution

    **Artifact:** `#{Paths.qa_journey_result()}`

    Execute each journey from the plan using browser tools, recording results
    and capturing evidence.

    #{server_note}

    #{qa_plan_note}

    ### Steps

    1. Ensure the Phoenix server is running
    2. Run seed scripts from the journey plan prerequisites
    3. Execute each journey step by step using browser tools
    4. For each journey, record:
       - Whether it passed or failed
       - Steps taken and observations
       - Screenshots as evidence
    5. Write the result to `#{Paths.qa_journey_result()}` following this format:

    #{ctx.result_spec}\
    """
  end

  # -- Phase 3: Wallaby Test Generation -----------------------------------------

  defp build_phase_3(ctx) do
    existing_tests_section = build_existing_tests_section(ctx.existing_wallaby)

    """
    ## Phase 3: Wallaby Test Generation

    **Artifact:** `#{@wallaby_dir}/*_test.exs`

    Convert passing QA journeys into permanent Wallaby regression tests.
    #{existing_tests_section}
    ### Steps

    1. Read the journey plan and result
    2. For each **passing** journey, write a Wallaby feature test:
       - Create test files in `#{@wallaby_dir}/`
       - Name files descriptively: `{journey_name}_test.exs`
       - Each test follows the journey steps using Wallaby browser automation
       - Assert expected outcomes from the journey plan
    3. Follow Wallaby conventions:
       - `use MyAppWeb.FeatureCase` or equivalent
       - Use `visit/2`, `fill_in/3`, `click/2`, `assert_has/2` etc.
       - Include setup for seeds/auth from the prerequisites
    4. Ensure tests are idempotent and can run independently
    5. Stop the session when done.\
    """
  end

  defp build_existing_tests_section([]), do: ""

  defp build_existing_tests_section(files) do
    file_list = Enum.map_join(files, "\n", &"- `#{&1}`")

    """

    These journey tests already exist — update or extend rather than duplicating:

    #{file_list}
    """
  end
end
