defmodule CodeMySpec.AgentTasks.ResearchTopics do
  @moduledoc """
  Container task for ensuring all decided technology topics have adequate research coverage.

  Identifies which topics need research (decided minus pre-made minus framework-covered),
  generates an orchestration prompt with dispatch instructions, and delegates per-topic
  validation to ResearchTopic.

  Follows the same pattern as ContextComponentSpecs — `command/3` returns the instructional
  prompt, `evaluate/3` checks children via ResearchTopic.evaluate/3.

  Prerequisite: `technical_strategy` must be satisfied (all ADRs and index exist).
  """

  require Logger

  alias CodeMySpec.AgentTasks.{ResearchTopic, TechnicalStrategy}
  alias CodeMySpec.{Environments, Paths}
  alias CodeMySpec.Users.Scope

  @doc """
  Generate the orchestration prompt listing topics that need research and dispatch instructions.

  Returns `{:ok, prompt_text}`.
  """
  @spec command(Scope.t(), map(), keyword()) :: {:ok, String.t()}
  def command(scope, _session, _opts \\ []) do
    env = scope.environment

    decided = list_decided_topics(env)
    premade = premade_topics()
    framework = list_framework_topics(env)

    qualifying = compute_qualifying(decided, premade, framework)

    skipped_premade = Enum.filter(decided, &(&1 in premade))
    skipped_framework = Enum.filter(decided, &(&1 in framework))

    topics_with_content =
      Enum.map(qualifying, fn topic ->
        adr_content = read_adr(env, topic)
        {topic, adr_content}
      end)

    prompt = build_command_prompt(topics_with_content, skipped_premade, skipped_framework)
    {:ok, prompt}
  end

  @doc """
  Check whether all qualifying topics have completed ResearchTopic validation.

  Returns:
  - `{:ok, :valid}` when all qualifying topics pass
  - `{:ok, :invalid, feedback}` when some topics fail
  """
  @spec evaluate(Scope.t(), map(), keyword()) ::
          {:ok, :valid} | {:ok, :invalid, String.t()}
  def evaluate(scope, _session, _opts \\ []) do
    env = scope.environment

    decided = list_decided_topics(env)
    premade = premade_topics()
    framework = list_framework_topics(env)

    qualifying = compute_qualifying(decided, premade, framework)

    Logger.info(
      "[ResearchTopics] evaluate: #{length(qualifying)} qualifying topics out of #{length(decided)} decided"
    )

    if Enum.empty?(qualifying) do
      {:ok, :valid}
    else
      check_qualifying_topics(scope, qualifying)
    end
  end

  # ============================================================================
  # Data Loading
  # ============================================================================

  defp compute_qualifying(decided, premade, framework) do
    # Use explicit parentheses — Elixir's -- is right-associative
    (decided -- premade) -- framework
  end

  defp list_decided_topics(env) do
    case Environments.glob(env, "#{Paths.decisions_dir()}/*.md") do
      files when is_list(files) ->
        files
        |> Enum.map(&Path.basename(&1, ".md"))
        |> Enum.sort()

      _ ->
        []
    end
  end

  defp premade_topics do
    TechnicalStrategy.premade_decisions()
    |> Enum.map(& &1.topic)
  end

  defp list_framework_topics(env) do
    case Environments.glob(env, "#{Paths.framework_dir()}/*") do
      entries when is_list(entries) ->
        Enum.map(entries, &framework_entry_to_topic/1)

      _ ->
        []
    end
  end

  defp framework_entry_to_topic(entry) do
    basename = Path.basename(entry)

    if File.dir?(entry) do
      basename
    else
      Path.basename(basename, ".md")
    end
  end

  defp read_adr(env, topic) do
    path = "#{Paths.decisions_dir()}/#{topic}.md"

    case Environments.read_file(env, path) do
      {:ok, content} -> content
      _ -> nil
    end
  end

  defp check_qualifying_topics(scope, qualifying) do
    incomplete = Enum.reject(qualifying, &topic_valid?(scope, &1))

    if Enum.empty?(incomplete) do
      {:ok, :valid}
    else
      feedback = build_evaluate_feedback(incomplete)
      {:ok, :invalid, feedback}
    end
  end

  defp topic_valid?(scope, topic) do
    child_session = %{state: %{"topic" => topic}}

    case ResearchTopic.evaluate(scope, child_session) do
      {:ok, :valid} -> true
      _ -> false
    end
  end

  # ============================================================================
  # Prompt Building
  # ============================================================================

  defp build_command_prompt(topics_with_content, skipped_premade, skipped_framework) do
    sections =
      [
        build_header(),
        build_topics_section(topics_with_content),
        build_dispatch_instructions(topics_with_content),
        build_skipped_section(skipped_premade, skipped_framework),
        build_stop_instruction()
      ]
      |> Enum.reject(&is_nil/1)

    Enum.join(sections, "\n\n")
  end

  defp build_header do
    """
    # Research Topics

    You are conducting deep research on the technology decisions made for this project.

    For each topic listed below, dispatch a subagent to research the technology and
    produce knowledge entries in `.code_my_spec/knowledge/{topic}/`.
    """
  end

  defp build_topics_section([]) do
    """
    ## Topics Needing Research

    No topics need research at this time. All decided topics are either pre-made
    decisions or covered by the framework knowledge directory.
    """
  end

  defp build_topics_section(topics_with_content) do
    topic_entries =
      Enum.map_join(topics_with_content, "\n\n", fn {topic, adr_content} ->
        build_topic_entry(topic, adr_content)
      end)

    """
    ## Topics Needing Research

    #{topic_entries}
    """
  end

  defp build_topic_entry(topic, nil) do
    "### #{topic}\n\nNo ADR content found for this topic."
  end

  defp build_topic_entry(topic, adr_content) do
    """
    ### #{topic}

    #{adr_content}
    """
    |> String.trim_trailing()
  end

  defp build_dispatch_instructions([]) do
    nil
  end

  defp build_dispatch_instructions(_topics_with_content) do
    """
    ## Dispatch Instructions

    For each topic above, dispatch a subagent to conduct the research. Subagents can
    run in parallel — each topic's research is independent.

    Each subagent should:
    1. Read the relevant ADR in `.code_my_spec/architecture/decisions/{topic}.md`
    2. Conduct deep research on the technology
    3. Write knowledge entries to `.code_my_spec/knowledge/{topic}/`

    Once all subagents have completed, stop the session so validation can check the work.
    """
  end

  defp build_skipped_section([], []) do
    nil
  end

  defp build_skipped_section(skipped_premade, skipped_framework) do
    parts = []

    parts =
      if Enum.empty?(skipped_premade) do
        parts
      else
        topic_list = Enum.map_join(skipped_premade, "\n", &"- `#{&1}`")

        [
          """
          ### Skipped: Pre-made decisions

          The following topics are part of the standard CodeMySpec stack and do not
          require additional research:

          #{topic_list}
          """
          | parts
        ]
      end

    parts =
      if Enum.empty?(skipped_framework) do
        parts
      else
        topic_list = Enum.map_join(skipped_framework, "\n", &"- `#{&1}`")

        [
          """
          ### Skipped: Already covered by framework knowledge

          The following topics are covered by existing framework documentation and do
          not require additional research:

          #{topic_list}
          """
          | parts
        ]
      end

    content =
      parts
      |> Enum.reverse()
      |> Enum.join("\n")

    """
    ## Skipped Topics

    #{content}
    """
  end

  defp build_stop_instruction do
    """
    ## Stop

    When all subagents have completed their research, stop the session so validation
    can check the work.
    """
  end

  # ============================================================================
  # Evaluation Feedback
  # ============================================================================

  defp build_evaluate_feedback(incomplete_topics) do
    topic_list = Enum.map_join(incomplete_topics, "\n", &"- #{&1}")

    """
    Research topics are incomplete.

    The following topics still need knowledge entries:

    #{topic_list}

    For each topic, knowledge entries must exist in `.code_my_spec/knowledge/{topic}/`.
    Dispatch subagents to research the remaining topics and stop the session again.
    """
  end
end
