defmodule CodeMySpec.AgentTasks.TechnicalStrategy do
  @moduledoc """
  Orchestrator task for identifying and resolving technology decisions.

  Analyzes the project's architecture and stories to identify topics that
  need technology decisions (e.g., which testing library, which deployment
  approach), then delegates per-topic validation to ResearchTopic.

  Follows the DevelopContext orchestration pattern:
  - `command/3` builds an orchestration prompt
  - `evaluate/3` checks all topics via ResearchTopic.evaluate

  Artifacts produced:
  - `docs/architecture/decisions.md` — index of all decisions
  - `docs/architecture/decisions/{topic}.md` — individual decision records
  - `docs/knowledge/{topic}/` — research findings (optional)
  - `docs/status/research/{topic}.md` — transient research prompts (cleaned up)
  """

  require Logger

  alias CodeMySpec.AgentTasks.ResearchTopic
  alias CodeMySpec.{Components, Environments, Stories}

  @decisions_dir "docs/architecture/decisions"
  @decisions_index "docs/architecture/decisions.md"
  @research_dir "docs/status/research"

  @doc """
  Generate the orchestration prompt for the technical strategy session.

  Reads architecture overview, project deps, existing decisions, and story
  titles, then builds a prompt instructing the agent to identify technology
  topics and write research prompts for each.

  Returns {:ok, prompt_text}
  """
  def command(scope, _session, _opts \\ []) do
    env = scope.environment
    project = scope.active_project

    component_count = Components.count_components(scope)
    mix_exs = read_mix_exs(env)
    existing_decisions = list_existing_decisions(env)
    story_titles = list_story_titles(scope)

    prompt =
      build_prompt(project, component_count, mix_exs, existing_decisions, story_titles)

    {:ok, prompt}
  end

  @doc """
  Validate all research topics are complete.

  Lists prompt files in `docs/status/research/` — each filename is a topic.
  For each topic, delegates to ResearchTopic.evaluate. Also validates the
  decisions index exists.

  Returns:
  - {:ok, :valid} if all topics pass and decisions.md exists
  - {:ok, :invalid, feedback} if topics are incomplete
  """
  def evaluate(scope, session, _opts \\ []) do
    env = scope.environment

    topics = list_research_topics(env)
    index_exists = decisions_index_exists?(env)

    Logger.info(
      "[TechnicalStrategy] evaluate: #{length(topics)} topic(s), index_exists=#{index_exists}"
    )

    if Enum.empty?(topics) and index_exists do
      {:ok, :valid}
    else
      evaluate_topics(scope, session, topics, index_exists)
    end
  end

  # ============================================================================
  # Data Loading
  # ============================================================================

  defp read_mix_exs(env) do
    case Environments.read_file(env, "mix.exs") do
      {:ok, content} -> content
      _ -> nil
    end
  end

  defp list_existing_decisions(env) do
    case Environments.glob(env, "#{@decisions_dir}/*.md") do
      files when is_list(files) ->
        files
        |> Enum.map(&Path.basename(&1, ".md"))
        |> Enum.sort()

      _ ->
        []
    end
  end

  defp list_story_titles(scope) do
    Stories.list_story_titles(scope)
    |> Enum.map(& &1.title)
  rescue
    _ -> []
  end

  defp list_research_topics(env) do
    case Environments.glob(env, "#{@research_dir}/*.md") do
      files when is_list(files) ->
        Enum.map(files, &Path.basename(&1, ".md"))

      _ ->
        []
    end
  end

  defp decisions_index_exists?(env) do
    Environments.file_exists?(env, @decisions_index) == true
  end

  # ============================================================================
  # Prompt Building
  # ============================================================================

  defp build_prompt(project, component_count, mix_exs, existing_decisions, story_titles) do
    sections =
      [
        build_header(project),
        build_architecture_section(component_count),
        build_deps_section(mix_exs),
        build_existing_decisions_section(existing_decisions),
        build_stories_section(story_titles),
        build_instructions()
      ]
      |> Enum.reject(&is_nil/1)

    Enum.join(sections, "\n\n")
  end

  defp build_header(project) do
    """
    # Technical Strategy Session

    You are conducting a technical strategy session for the **#{project.name}** project.

    Your goal is to identify technology decisions that need to be made, research the
    options, and produce decision records with supporting knowledge.
    """
  end

  defp build_architecture_section(0), do: nil

  defp build_architecture_section(component_count) do
    """
    ## Architecture Overview

    The project has #{component_count} components defined. Review the architecture views for details:

    - **Overview:** `docs/architecture/overview.md`
    - **Dependency Graph:** `docs/architecture/dependency_graph.mmd`
    - **Namespace Hierarchy:** `docs/architecture/namespace_hierarchy.md`
    """
  end

  defp build_deps_section(nil), do: nil

  defp build_deps_section(mix_exs) do
    """
    ## Current Dependencies

    ```elixir
    #{mix_exs}
    ```
    """
  end

  defp build_existing_decisions_section([]), do: nil

  defp build_existing_decisions_section(decisions) do
    decision_list = Enum.map_join(decisions, "\n", &"- `#{&1}`")

    """
    ## Existing Decisions

    The following topics already have decision records in `#{@decisions_dir}/`:

    #{decision_list}

    Review these to avoid duplicating work. You can update existing decisions if needed.
    """
  end

  defp build_stories_section([]), do: nil

  defp build_stories_section(titles) do
    story_list = Enum.map_join(titles, "\n", &"- #{&1}")

    """
    ## User Stories

    These stories inform what technology decisions may be needed:

    #{story_list}
    """
  end

  defp build_instructions do
    """
    ## Instructions

    ### Step 1: Identify Topics

    Analyze the architecture, stories, and current dependencies to identify technology
    decisions that need to be made. Common categories include:

    - **Testing:** Integration test framework, E2E approach, test data strategy
    - **Deployment:** Hosting, CI/CD, release strategy
    - **Infrastructure:** Caching, background jobs, file storage
    - **Frontend:** CSS framework, JS bundling, component library
    - **Integrations:** Third-party APIs, payment processing, auth providers

    ### Step 2: Write Research Prompts

    For each topic you identify, write a freeform research prompt to
    `docs/status/research/{topic}.md`. The filename becomes the topic name.

    Example: `docs/status/research/wallaby.md` might contain:
    ```
    Research Wallaby for browser-based integration testing of Phoenix LiveView.
    Compare with alternatives like Hound. Consider CI setup requirements.
    ```

    ### Step 3: Research Each Topic

    For each research prompt file, invoke the **researcher** subagent
    (`@"CodeMySpec:researcher (agent)"`) to:
    - Search documentation and community resources
    - Evaluate options against project requirements
    - Write findings to `docs/knowledge/{topic}/` (optional)
    - Write a decision record to `docs/architecture/decisions/{topic}.md`

    ### Step 4: Update the Index

    Ensure `#{@decisions_index}` exists and lists all decision records with
    their status.

    ### Step 5: Stop

    When all topics have been researched and decisions recorded, stop the session
    so validation can check your work.
    """
  end

  # ============================================================================
  # Evaluation
  # ============================================================================

  defp evaluate_topics(scope, session, topics, index_exists) do
    topic_results =
      Enum.map(topics, fn topic ->
        child_session = build_child_session(session, topic)

        case ResearchTopic.evaluate(scope, child_session) do
          {:ok, :valid} -> {topic, :valid}
          {:ok, :invalid, feedback} -> {topic, {:invalid, feedback}}
        end
      end)

    incomplete =
      Enum.filter(topic_results, fn
        {_topic, :valid} -> false
        _ -> true
      end)

    cond do
      Enum.empty?(incomplete) and index_exists ->
        {:ok, :valid}

      not index_exists ->
        feedback = build_evaluate_feedback(incomplete, false)
        {:ok, :invalid, feedback}

      true ->
        feedback = build_evaluate_feedback(incomplete, true)
        {:ok, :invalid, feedback}
    end
  end

  defp build_child_session(session, topic) do
    %{
      project: Map.get(session, :project),
      state: %{"topic" => topic}
    }
  end

  defp build_evaluate_feedback(incomplete_topics, index_exists) do
    parts = []

    parts =
      if index_exists do
        parts
      else
        ["- Decisions index not found at `#{@decisions_index}`" | parts]
      end

    parts =
      Enum.reduce(incomplete_topics, parts, fn {topic, _status}, acc ->
        ["- Topic \"#{topic}\" is incomplete" | acc]
      end)

    issue_list = parts |> Enum.reverse() |> Enum.join("\n")

    """
    Technical strategy is incomplete:

    #{issue_list}

    Address the remaining topics and stop the session again.
    """
  end
end
