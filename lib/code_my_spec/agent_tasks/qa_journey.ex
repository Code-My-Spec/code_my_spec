defmodule CodeMySpec.AgentTasks.QaJourney do
  @moduledoc """
  Plan, execute, and codify end-to-end QA journeys as a three-phase pipeline.

  See spec: `.code_my_spec/spec/code_my_spec/agent_tasks/qa_journey.spec.md`.
  """

  alias CodeMySpec.Documents.DocumentSpecProjector
  alias CodeMySpec.{Environments, Paths, Stories}

  @stories_file Path.join(Paths.qa_dir(), "stories_summary.md")
  @wallaby_dir Paths.qa_journey_wallaby_dir()

  def dispatch(_node) do
    "Plan, execute, and codify end-to-end QA journeys: design cross-story " <>
      "user paths, walk them in a browser, then convert passing journeys " <>
      "into Wallaby regression tests under `test/journeys/`. Use when " <>
      "BDD specs pass but the app has no end-to-end coverage."
  end

  @doc """
  Build the combined QA journey prompt covering all three phases.

  Phases whose artifacts already exist are collapsed to a SKIP marker so
  the agent works on the first un-skipped phase per session.
  """
  def command(scope, _task) do
    env = scope.environment

    stories = list_stories(scope)
    write_stories_file(env, stories)

    ctx = %{
      stories: stories,
      plan_spec: DocumentSpecProjector.project_spec("qa_journey_plan"),
      result_spec: DocumentSpecProjector.project_spec("qa_journey_result"),
      qa_plan_exists: Environments.file_exists?(env, Paths.qa_plan()) == true,
      journey_plan_exists: Environments.file_exists?(env, Paths.qa_journey_plan()) == true,
      journey_result_exists: Environments.file_exists?(env, Paths.qa_journey_result()) == true,
      existing_wallaby: list_wallaby_tests(env),
      architecture_exists:
        Environments.file_exists?(env, Path.join(Paths.architecture_dir(), "overview.md")) == true
    }

    {:ok, build_prompt(ctx)}
  end

  # ============================================================================
  # Data Loading
  # ============================================================================

  defp list_stories(scope) do
    Stories.list_stories(scope)
  end

  defp list_wallaby_tests(env) do
    case Environments.glob(env, Path.join(@wallaby_dir, "*_test.exs")) do
      files when is_list(files) -> files
      _ -> []
    end
  end

  defp write_stories_file(_env, []), do: :ok

  defp write_stories_file(env, stories) do
    content =
      Enum.map_join(stories, "\n\n", fn story ->
        criteria = format_criteria(Map.get(story, :criteria, []))

        """
        ## Story #{story.id} — #{story.title}

        #{story.description || "(no description)"}

        #{criteria}\
        """
      end)

    Environments.write_file(env, @stories_file, "# Stories\n\n" <> content)
  end

  defp format_criteria([]), do: "_No acceptance criteria._"

  defp format_criteria(criteria) do
    Enum.map_join(criteria, "\n", fn c -> "- #{c.description}" end)
  end

  # ============================================================================
  # Prompt Building
  # ============================================================================

  defp build_prompt(ctx) do
    [
      build_header(),
      build_context_section(ctx),
      build_stories_section(ctx),
      build_phase_1(ctx),
      build_phase_2(ctx),
      build_phase_3(ctx),
      build_playbook_footer()
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n\n")
  end

  defp build_header do
    """
    # QA Journey: Plan → Execute → Codify

    Three phases, one session at a time. Each phase produces an artifact;
    phases whose artifacts already exist are marked SKIP — work the first
    un-skipped phase. The full procedure lives in the playbook
    (read `qa_journey/workflow.md` via the `read_knowledge` MCP tool).\
    """
  end

  defp build_context_section(ctx) do
    architecture_path = Path.join(Paths.architecture_dir(), "overview.md")

    items =
      [
        ctx.qa_plan_exists && "- `#{Paths.qa_plan()}` — QA infrastructure",
        ctx.architecture_exists && "- `#{architecture_path}` — component graph",
        ctx.journey_plan_exists && "- `#{Paths.qa_journey_plan()}` — existing plan",
        ctx.journey_result_exists && "- `#{Paths.qa_journey_result()}` — existing result"
      ]
      |> Enum.filter(& &1)

    case items do
      [] ->
        """
        ## Context

        No QA plan or architecture overview found. Read the app's router
        and config directly to understand routes, auth, and features.\
        """

      _ ->
        """
        ## Context

        Read these before designing or executing journeys:

        #{Enum.join(items, "\n")}\
        """
    end
  end

  defp build_stories_section(%{stories: []}) do
    """
    ## Stories

    No stories found. Design journeys based on the app's routes and features.\
    """
  end

  defp build_stories_section(%{stories: stories}) do
    titles = Enum.map_join(stories, "\n", fn s -> "- Story #{s.id} — #{s.title}" end)

    """
    ## Stories

    #{titles}

    Full descriptions and acceptance criteria: `#{@stories_file}`.\
    """
  end

  # -- Phase 1 -----------------------------------------------------------------

  defp build_phase_1(%{journey_plan_exists: true}) do
    """
    ## Phase 1: Journey Planning — SKIP

    Plan already at `#{Paths.qa_journey_plan()}`. Proceed to Phase 2.\
    """
  end

  defp build_phase_1(%{plan_spec: plan_spec}) do
    """
    ## Phase 1: Journey Planning

    **Artifact:** `#{Paths.qa_journey_plan()}`

    Design 3–5 end-to-end journeys that cut across stories — see the
    playbook for procedure and anti-patterns. Write the plan to match:

    #{plan_spec}\
    """
  end

  # -- Phase 2 -----------------------------------------------------------------

  defp build_phase_2(%{journey_result_exists: true}) do
    """
    ## Phase 2: Journey Execution — SKIP

    Result already at `#{Paths.qa_journey_result()}`. Proceed to Phase 3.\
    """
  end

  defp build_phase_2(%{result_spec: result_spec}) do
    """
    ## Phase 2: Journey Execution

    **Artifact:** `#{Paths.qa_journey_result()}`

    Execute each journey from the plan with browser tools, capturing
    screenshots as evidence. Server-prereq checklist and tool-by-pipeline
    rules are in the playbook. Write the result to match:

    #{result_spec}\
    """
  end

  # -- Phase 3 -----------------------------------------------------------------

  defp build_phase_3(%{existing_wallaby: existing}) do
    existing_note =
      case existing do
        [] ->
          ""

        files ->
          "\n\nUpdate rather than duplicate these existing tests:\n\n" <>
            Enum.map_join(files, "\n", &"- `#{&1}`")
      end

    """
    ## Phase 3: Wallaby Test Generation

    **Artifact:** `#{@wallaby_dir}/{journey_name}_test.exs`

    Convert each **passing** journey from Phase 2 into a Wallaby feature
    test under `#{@wallaby_dir}/`. Run the file once to confirm it's
    green before stopping. Conventions live in the playbook.#{existing_note}\
    """
  end

  defp build_playbook_footer do
    """
    ## Read the playbook

    Read `qa_journey/workflow.md` via the `read_knowledge` MCP tool —
    full three-phase procedure, server-prereq checklist, tool-by-pipeline
    rules (browser tools vs curl), screenshot evidence requirements,
    Wallaby conventions, anti-patterns per phase.\
    """
  end
end
