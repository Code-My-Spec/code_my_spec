defmodule CodeMySpec.AgentTasks.ResearchTopic do
  @moduledoc """
  Per-topic agent task for deep research on a technology decision.

  Generates a self-contained research prompt that includes the full research
  methodology, evaluation criteria, and output format. The prompt file is written
  to a tasks directory and picked up by whatever subagent the orchestrator
  dispatches — no specific subagent is required.

  In the requirement flow, this task runs AFTER TechnicalStrategy has created the
  ADR. Its job is deep research: searching Hex.pm, reading official docs, evaluating
  community health, and producing knowledge entries. The ADR already exists and
  provides context for the research.

  Produces:
  - `.code_my_spec/knowledge/{topic}/` — knowledge entries (getting_started.md, etc.)

  Cleans up `.code_my_spec/tasks/research/{topic}.md` on successful validation.
  """

  alias CodeMySpec.{Environments, Paths}

  @doc """
  Generate the self-contained research prompt for a single topic.

  The prompt includes all research methodology, evaluation criteria, and output
  templates so the executing agent needs no external instructions.

  The topic is taken from `task.requirement_name` (with fallback to `task.state["topic"]`).

  Returns `{:ok, prompt_text}`.
  """
  @spec command(CodeMySpec.Users.Scope.t(), map()) :: {:ok, String.t()}
  def command(scope, task) do
    topic = get_topic(task)
    env = scope.environment

    research_brief = read_research_brief(env, topic)
    mix_exs = read_mix_exs(env)
    adr_content = read_adr(env, topic)
    existing_knowledge = check_existing_knowledge(env, topic)

    prompt = build_prompt(topic, research_brief, mix_exs, adr_content, existing_knowledge)
    {:ok, prompt}
  end

  @doc """
  Validate the topic has knowledge entries.

  Checks that at least one knowledge file exists in `.code_my_spec/knowledge/{topic}/`.
  On success, cleans up the research prompt file.

  Returns:
  - `{:ok, :valid}` when knowledge entries exist
  - `{:ok, :invalid, feedback}` when no knowledge entries exist
  """
  @spec evaluate(CodeMySpec.Users.Scope.t(), map()) ::
          {:ok, :valid} | {:ok, :invalid, String.t()}
  def evaluate(scope, task) do
    topic = get_topic(task)
    env = scope.environment

    knowledge_files = check_existing_knowledge(env, topic)

    if knowledge_files != [] do
      cleanup_research_prompt(env, topic)
      {:ok, :valid}
    else
      feedback = build_invalid_feedback(topic)
      {:ok, :invalid, feedback}
    end
  end

  # ============================================================================
  # Helpers
  # ============================================================================

  defp get_topic(%{requirement_name: name}) when is_binary(name) and name != "", do: name
  defp get_topic(%{state: %{"topic" => topic}}) when is_binary(topic) and topic != "", do: topic
  defp get_topic(_task), do: raise("ResearchTopic requires task.requirement_name or state[\"topic\"]")

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

  defp read_adr(env, topic) do
    path = "#{Paths.decisions_dir()}/#{topic}.md"

    case Environments.read_file(env, path) do
      {:ok, content} -> content
      _ -> nil
    end
  end

  defp check_existing_knowledge(env, topic) do
    pattern = Paths.knowledge_topic_glob(topic)

    case Environments.glob(env, pattern) do
      files when is_list(files) and files != [] -> files
      _ -> []
    end
  end

  defp cleanup_research_prompt(env, topic) do
    path = "#{Paths.research_dir()}/#{topic}.md"
    Environments.delete_file(env, path)
    :ok
  end

  # ============================================================================
  # Prompt Building
  # ============================================================================

  defp build_prompt(topic, research_brief, mix_exs, adr_content, existing_knowledge) do
    sections =
      [
        build_header(topic),
        build_decision_context_section(topic, adr_content),
        build_research_brief_section(research_brief),
        build_deps_section(mix_exs),
        build_existing_knowledge_section(topic, existing_knowledge),
        build_methodology_section(),
        build_evaluation_criteria_section(),
        build_output_instructions_section(topic),
        build_stop_instruction()
      ]
      |> Enum.reject(&is_nil/1)

    Enum.join(sections, "\n\n")
  end

  defp build_header(topic) do
    """
    # Research Topic: #{topic}

    You are conducting deep research on **#{topic}** to produce knowledge entries
    that support the project's technology decision.
    """
  end

  defp build_decision_context_section(_topic, nil), do: nil

  defp build_decision_context_section(topic, content) do
    """
    ## Decision Context

    The following decision record for **#{topic}** was created during technical strategy.
    Use it to understand what was decided and why, and let it guide your research focus:

    ```markdown
    #{content}
    ```
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
    file_list = Enum.map_join(files, "\n", &"- `#{Path.basename(&1)}`")

    """
    ## Existing Knowledge

    There are already knowledge entries for **#{topic}** in
    `#{Paths.knowledge_dir()}/#{topic}/`:

    #{file_list}

    Review these before producing new content. Update or extend existing files
    rather than duplicating material.
    """
  end

  defp build_methodology_section do
    """
    ## Research Methodology

    Follow these steps in order:

    1. **Search Hex.pm** — find the package on hex.pm, check download count, last release
       date, maintenance status, and open issues count. Use `mix hex.info {package}` or
       fetch `https://hex.pm/packages/{package}` directly.

    2. **Read official documentation** — fetch the package's HexDocs
       (`https://hexdocs.pm/{package}`) or GitHub README for setup guides, configuration
       options, and API surface.

    3. **Inspect project context** — read `mix.exs` for current deps and Elixir/OTP
       versions, check `config/` for existing patterns, scan `lib/` and `test/` for
       relevant usage.

    4. **Compare alternatives** — if the topic is a category (e.g., "HTTP client") rather
       than a specific library, search for and compare the top 2-3 options.

    5. **Check community health** — search Elixir Forum (elixirforum.com), GitHub
       issues/discussions for known problems, migration guides, or community endorsements.
    """
  end

  defp build_evaluation_criteria_section do
    """
    ## Evaluation Criteria

    When assessing options, apply these criteria:

    - **Compatibility** — works with current stack (Phoenix 1.8, LiveView 1.1, OTP version)?
    - **Maintenance** — actively maintained? Releases in last 6 months?
    - **Community** — good docs? Responsive maintainer? Adoption level?
    - **Complexity** — setup burden? Ongoing maintenance cost?
    - **Testing** — how does it affect the test suite? ExVCR compatible?
    """
  end

  defp build_output_instructions_section(topic) do
    knowledge_dir = "#{Paths.knowledge_dir()}/#{topic}"
    decisions_dir = "#{Paths.decisions_dir()}/#{topic}.md"

    """
    ## Output Instructions

    1. **Write knowledge entries** — write to `#{knowledge_dir}/` with one file per
       sub-topic (e.g., `getting_started.md`, `configuration.md`, `patterns.md`).
       Include code examples relevant to the project. Focus on practical, actionable
       information.

    2. **Update the ADR if needed** — if research reveals new information that changes
       or clarifies the decision, update the existing decision record at `#{decisions_dir}`.
    """
  end

  defp build_stop_instruction do
    """
    ## Stop

    When you have written at least one knowledge entry, stop the session so validation
    can check your work.
    """
  end

  # ============================================================================
  # Evaluation Feedback
  # ============================================================================

  defp build_invalid_feedback(topic) do
    knowledge_dir = "#{Paths.knowledge_dir()}/#{topic}"

    """
    Research topic "#{topic}" is incomplete.

    No knowledge entries were found in `#{knowledge_dir}/`.

    Write at least one knowledge file (e.g., `getting_started.md`) and stop the
    session again.
    """
  end
end
