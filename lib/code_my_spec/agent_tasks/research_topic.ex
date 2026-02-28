defmodule CodeMySpec.AgentTasks.ResearchTopic do
  @moduledoc """
  Per-topic agent task for researching a technology decision.

  Handles researching a single topic and producing its artifacts:
  - A decision record at `.code_my_spec/architecture/decisions/{topic}.md`
  - An index entry in `.code_my_spec/architecture/decisions.md`
  - Optionally, knowledge entries in `.code_my_spec/knowledge/{topic}/`

  Can be invoked standalone or delegated to by TechnicalStrategy.

  Two main functions:
  - `command/3` - Generates the research prompt for a single topic
  - `evaluate/3` - Validates the topic has a decision record and index entry
  """

  alias CodeMySpec.{Environments, Paths}

  @doc """
  Generate the research prompt for a single topic.

  Reads the freeform research brief (if one exists), checks for existing
  artifacts, and builds a prompt instructing the agent to produce a
  decision record and optionally knowledge entries.

  The topic is taken from `session.state["topic"]`.

  Returns {:ok, prompt_text}
  """
  def command(scope, session, _opts \\ []) do
    topic = get_topic(session)
    env = scope.environment

    research_brief = read_research_brief(env, topic)
    mix_exs = read_mix_exs(env)
    existing_knowledge = check_existing_knowledge(env, topic)
    existing_decision = check_existing_decision(env, topic)

    prompt = build_prompt(topic, research_brief, mix_exs, existing_knowledge, existing_decision)
    {:ok, prompt}
  end

  @doc """
  Validate the topic's artifacts are complete.

  Checks:
  1. Decision record exists at `.code_my_spec/architecture/decisions/{topic}.md` and is non-empty
  2. Decisions index exists and references the topic
  3. On success, cleans up the research prompt file

  Returns:
  - {:ok, :valid} if all checks pass
  - {:ok, :invalid, feedback} if something is missing
  """
  def evaluate(scope, session, _opts \\ []) do
    topic = get_topic(session)
    env = scope.environment
    working_dir = env && env.cwd

    issues = []

    issues = check_decision_record(env, topic, issues)
    issues = check_decisions_index(env, topic, issues)

    case issues do
      [] ->
        cleanup_research_prompt(topic, working_dir)
        {:ok, :valid}

      issues ->
        feedback = format_feedback(topic, issues)
        {:ok, :invalid, feedback}
    end
  end

  # ============================================================================
  # Helpers
  # ============================================================================

  defp get_topic(%{state: %{"topic" => topic}}), do: topic
  defp get_topic(_session), do: raise("ResearchTopic requires session.state[\"topic\"]")

  defp read_research_brief(env, topic) do
    path = "#{Paths.research_dir()}/#{topic}.md"

    case Environments.read_file(env, path) do
      {:ok, content} -> content
      _ -> nil
    end
  end

  defp read_mix_exs(env) do
    case Environments.read_file(env, "mix.exs") do
      {:ok, content} -> content
      _ -> nil
    end
  end

  defp check_existing_knowledge(env, topic) do
    pattern = "#{Paths.knowledge_dir()}/#{topic}/**"

    case Environments.glob(env, pattern) do
      files when is_list(files) and files != [] -> files
      _ -> []
    end
  end

  defp check_existing_decision(env, topic) do
    path = "#{Paths.decisions_dir()}/#{topic}.md"

    case Environments.read_file(env, path) do
      {:ok, content} -> content
      _ -> nil
    end
  end

  # ============================================================================
  # Prompt Building
  # ============================================================================

  defp build_prompt(topic, research_brief, mix_exs, existing_knowledge, existing_decision) do
    sections =
      [
        build_header(topic),
        build_research_brief_section(research_brief),
        build_deps_section(mix_exs),
        build_existing_knowledge_section(topic, existing_knowledge),
        build_existing_decision_section(topic, existing_decision),
        build_instructions(topic)
      ]
      |> Enum.reject(&is_nil/1)

    Enum.join(sections, "\n\n")
  end

  defp build_header(topic) do
    """
    # Research Topic: #{topic}

    You are researching the technology topic **#{topic}** to produce a decision record
    and optionally supporting knowledge entries.
    """
  end

  defp build_research_brief_section(nil), do: nil

  defp build_research_brief_section(brief) do
    """
    ## Research Brief

    The following freeform prompt was written to guide your research:

    #{brief}
    """
  end

  defp build_deps_section(nil), do: nil

  defp build_deps_section(mix_exs) do
    """
    ## Current Dependencies

    Here is the project's `mix.exs` for dependency context:

    ```elixir
    #{mix_exs}
    ```
    """
  end

  defp build_existing_knowledge_section(_topic, []), do: nil

  defp build_existing_knowledge_section(topic, files) do
    file_list = Enum.map_join(files, "\n", &"- `#{&1}`")

    """
    ## Existing Knowledge

    There are already knowledge entries for this topic in `#{Paths.knowledge_dir()}/#{topic}/`:

    #{file_list}

    Review these before producing new content. Update or extend as needed rather than
    duplicating existing material.
    """
  end

  defp build_existing_decision_section(_topic, nil), do: nil

  defp build_existing_decision_section(topic, content) do
    """
    ## Existing Decision Record

    A decision record already exists at `#{Paths.decisions_dir()}/#{topic}.md`:

    ```markdown
    #{content}
    ```

    Review and update this rather than starting from scratch.
    """
  end

  defp build_instructions(topic) do
    """
    ## Instructions

    Use the **researcher** subagent (`@"CodeMySpec:researcher (agent)"`) to:

    1. **Research the topic** — search for documentation, best practices, comparisons,
       and community recommendations. Inspect the project's `mix.exs`, `config/`, and
       existing code for relevant context.

    2. **Write knowledge entries** (optional) — if the research produces useful reference
       material, write it to `#{Paths.knowledge_dir()}/#{topic}/`. Use one file per sub-topic
       (e.g., `#{Paths.knowledge_dir()}/#{topic}/getting_started.md`).

    3. **Write the decision record** — write to `#{Paths.decisions_dir()}/#{topic}.md` with this structure:
       - **Title**: What was decided
       - **Status**: Accepted / Proposed / Superseded
       - **Context**: Why this decision was needed
       - **Options Considered**: Alternatives evaluated with pros/cons
       - **Decision**: What was chosen and why
       - **Consequences**: Trade-offs and implications

    4. **Update the index** — ensure `#{Paths.decisions_index()}` exists and includes a
       reference to this topic's decision record.

    When complete, stop the session so validation can check your work.
    """
  end

  # ============================================================================
  # Evaluation
  # ============================================================================

  defp check_decision_record(env, topic, issues) do
    path = "#{Paths.decisions_dir()}/#{topic}.md"

    case Environments.read_file(env, path) do
      {:ok, content} when is_binary(content) ->
        if String.trim(content) == "" do
          [{:empty_decision, "Decision record at `#{path}` is empty"} | issues]
        else
          issues
        end

      _ ->
        [{:missing_decision, "No decision record found at `#{path}`"} | issues]
    end
  end

  defp check_decisions_index(env, topic, issues) do
    case Environments.read_file(env, Paths.decisions_index()) do
      {:ok, content} ->
        if String.contains?(content, topic) do
          issues
        else
          [{:not_in_index, "Decisions index does not reference topic \"#{topic}\""} | issues]
        end

      _ ->
        [{:missing_index, "Decisions index not found at `#{Paths.decisions_index()}`"} | issues]
    end
  end

  defp cleanup_research_prompt(_topic, nil), do: :ok

  defp cleanup_research_prompt(topic, working_dir) do
    path = Path.join(working_dir, "#{Paths.research_dir()}/#{topic}.md")

    if File.exists?(path) do
      File.rm(path)
    end

    :ok
  end

  defp format_feedback(topic, issues) do
    issue_list =
      issues
      |> Enum.reverse()
      |> Enum.map_join("\n", fn {_type, message} -> "- #{message}" end)

    """
    Research topic "#{topic}" is incomplete:

    #{issue_list}

    Please address these issues and stop the session again.
    """
  end
end
