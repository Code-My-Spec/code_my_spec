defmodule CodeMySpec.AgentTasks.QaJourneyPlan do
  @moduledoc """
  Plans end-to-end QA journeys through the application.

  Produces a journey plan document at `.code_my_spec/qa/journey_plan.md`.
  Uses progressive disclosure — gives the agent file paths to read rather
  than inlining content.

  Two main functions:
  - `command/3` — Builds prompt with paths to read, writes journey_plan.md
  - `evaluate/3` — Checks required sections exist (journeys, prerequisites)
  """

  alias CodeMySpec.Documents.DocumentSpecProjector
  alias CodeMySpec.{Environments, Paths, Stories}

  @required_sections ["journeys", "prerequisites"]

  @doc """
  Generate the planning prompt for the QA journey plan session.

  Returns a concise prompt that points the agent at the files it needs to read,
  rather than inlining their contents.

  Returns `{:ok, prompt_text}`
  """
  @stories_file Path.join(Paths.qa_dir(), "stories_summary.md")

  def command(scope, _session, _opts \\ []) do
    env = scope.environment

    stories = list_stories(scope)
    doc_spec = DocumentSpecProjector.project_spec("qa_journey_plan")
    qa_plan_exists = Environments.file_exists?(env, Paths.qa_plan()) == true
    architecture_path = Path.join(Paths.architecture_dir(), "overview.md")
    architecture_exists = Environments.file_exists?(env, architecture_path) == true

    stories_file_written = write_stories_file(env, stories)

    prompt =
      build_prompt(
        stories,
        doc_spec,
        qa_plan_exists,
        architecture_exists,
        architecture_path,
        stories_file_written
      )

    {:ok, prompt}
  end

  @doc """
  Validate that journey_plan.md exists and contains the required sections.

  Returns:
  - `{:ok, :valid}` if journey_plan.md exists with all required sections
  - `{:ok, :invalid, feedback}` if missing or incomplete
  """
  def evaluate(scope, _session, _opts \\ []) do
    env = scope.environment
    plan_path = Paths.qa_journey_plan()

    case Environments.read_file(env, plan_path) do
      {:ok, content} when byte_size(content) > 0 ->
        validate_sections(content)

      _ ->
        {:ok, :invalid,
         "Journey plan not found at `#{plan_path}`. Write the plan and stop the session again."}
    end
  end

  # ============================================================================
  # Data Loading
  # ============================================================================

  defp list_stories(scope) do
    Stories.list_stories(scope)
  rescue
    _ -> []
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

  # ============================================================================
  # Prompt Building
  # ============================================================================

  defp build_prompt(
         stories,
         doc_spec,
         qa_plan_exists,
         architecture_exists,
         architecture_path,
         stories_file_written
       ) do
    sections =
      [
        build_header(),
        build_context_section(qa_plan_exists, architecture_exists, architecture_path),
        build_stories_section(stories, stories_file_written),
        build_doc_spec_section(doc_spec),
        build_instructions()
      ]
      |> Enum.reject(&is_nil/1)

    Enum.join(sections, "\n\n")
  end

  defp build_header do
    """
    # QA Journey Planning

    Design end-to-end QA journeys for this application. Each journey traces a complete
    user path — setup, authentication, core workflows, verification. Journeys test the
    app holistically, not story-by-story.\
    """
  end

  defp build_context_section(qa_plan_exists, architecture_exists, architecture_path) do
    read_items =
      [
        if(qa_plan_exists,
          do: "- `#{Paths.qa_plan()}` — QA infrastructure (tools, auth, seeds)"
        ),
        if(architecture_exists,
          do: "- `#{architecture_path}` — system component graph and dependencies"
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

  defp build_doc_spec_section(doc_spec) do
    """
    ## Output

    Write to `#{Paths.qa_journey_plan()}` following this format:

    #{doc_spec}\
    """
  end

  defp build_instructions do
    """
    ## Steps

    1. Read the context files listed above
    2. Design 3-5 end-to-end journeys covering the app's core workflows
    3. Each journey: name, user role, numbered steps, expected outcome
    4. Include a prerequisites section (server startup, seeds, credentials)
    5. Write to `#{Paths.qa_journey_plan()}`
    6. Stop the session when done.\
    """
  end

  # ============================================================================
  # Validation
  # ============================================================================

  defp validate_sections(content) do
    content_lower = String.downcase(content)

    missing =
      Enum.reject(@required_sections, fn section ->
        String.contains?(content_lower, "## #{section}")
      end)

    case missing do
      [] ->
        {:ok, :valid}

      sections ->
        section_list = Enum.map_join(sections, ", ", &"`## #{title_case(&1)}`")

        {:ok, :invalid,
         "Journey plan is missing required section(s): #{section_list}. Update the plan and stop the session again."}
    end
  end

  defp title_case(string) do
    string
    |> String.split(" ")
    |> Enum.map_join(" ", &String.capitalize/1)
  end
end
