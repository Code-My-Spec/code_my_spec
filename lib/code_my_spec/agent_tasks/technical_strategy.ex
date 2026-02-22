defmodule CodeMySpec.AgentTasks.TechnicalStrategy do
  @moduledoc """
  Orchestrator task for identifying and resolving technology decisions.

  Analyzes the project's architecture and stories to identify topics that
  need technology decisions (e.g., which testing library, which deployment
  approach), then delegates per-topic validation to ResearchTopic.

  Handles three phases:
  1. **Pre-made decisions** — writes ADRs for standard stack choices
  2. **Research** — identifies and researches new technology topics
  3. **Knowledge & Bootstrap** — builds knowledge base and configures libraries

  Artifacts produced:
  - `docs/architecture/decisions.md` — index of all decisions
  - `docs/architecture/decisions/{topic}.md` — individual decision records
  - `docs/knowledge/{topic}/` — research findings (required for non-pre-made topics)
  - `docs/status/research/{topic}.md` — transient research prompts (cleaned up)
  """

  require Logger

  alias CodeMySpec.AgentTasks.ResearchTopic
  alias CodeMySpec.{Components, Environments, Stories}

  @decisions_dir "docs/architecture/decisions"
  @decisions_index "docs/architecture/decisions.md"
  @knowledge_dir "docs/knowledge"
  @research_dir "docs/status/research"

  # Pre-made technology decisions that are part of the standard CodeMySpec stack.
  # These get written as accepted ADRs before any research begins.
  @premade_decisions [
    %{
      topic: "elixir",
      title: "Use Elixir as the primary language",
      context:
        "We need a functional, concurrent language with strong ecosystem support for web applications.",
      decision:
        "Use Elixir. It provides excellent concurrency via the BEAM VM, pattern matching, and a mature ecosystem for building reliable web applications."
    },
    %{
      topic: "phoenix",
      title: "Use Phoenix as the web framework",
      context:
        "We need a performant, productive web framework for building our application.",
      decision:
        "Use Phoenix. It provides excellent real-time capabilities, a productive development experience, and tight integration with Elixir's concurrency model."
    },
    %{
      topic: "liveview",
      title: "Use Phoenix LiveView for interactive UI",
      context:
        "We need rich, interactive user interfaces without the complexity of a JavaScript SPA framework.",
      decision:
        "Use Phoenix LiveView for all interactive UI. It enables server-rendered reactive interfaces over WebSockets, eliminating the need for a separate frontend build pipeline."
    },
    %{
      topic: "tailwind",
      title: "Use Tailwind CSS for styling",
      context:
        "We need a CSS approach that scales well and avoids naming collisions.",
      decision:
        "Use Tailwind CSS with its utility-first approach. It ships with Phoenix by default and integrates well with LiveView's component model."
    },
    %{
      topic: "daisyui",
      title: "Use DaisyUI as the component library",
      context:
        "We need pre-built UI components that work with Tailwind CSS to accelerate development.",
      decision:
        "Use DaisyUI on top of Tailwind CSS. It provides semantic component classes (btn, card, modal, etc.) with built-in theme support, reducing the amount of utility class composition needed."
    },
    %{
      topic: "phx-gen-auth",
      title: "Use phx.gen.auth for authentication",
      context:
        "We need user authentication with registration, login, and session management.",
      decision:
        "Use `mix phx.gen.auth` to generate authentication. It provides a well-tested, customizable authentication system that lives in the project's codebase rather than behind an opaque library."
    },
    %{
      topic: "exvcr",
      title: "Use ExVCR for HTTP recording in tests",
      context:
        "We need to test code that makes external HTTP calls without hitting real services in CI.",
      decision:
        "Use ExVCR to record and replay all external HTTP interactions. Record all external calls regardless of the HTTP client used. This ensures deterministic tests and documents the exact API interactions the system depends on."
    },
    %{
      topic: "bdd-testing",
      title: "Use BDD specs with SexySpex for end-to-end testing",
      context:
        "We need a testing approach that validates user-facing behavior and bridges the gap between stories and code.",
      decision:
        "Use BDD specifications with SexySpex (`sexy_spex`) for end-to-end tests. Write specs that test real user workflows through LiveView, combining recorded external interactions (ExVCR) with browser-level assertions."
    },
    %{
      topic: "dotenvy",
      title: "Use Dotenvy for environment management",
      context:
        "We need a way to manage environment variables across development, test, and production.",
      decision:
        "Use Dotenvy for environment variable management. It loads `.env` files in development and integrates cleanly with Elixir's config system via runtime configuration."
    },
    %{
      topic: "ngrok",
      title: "Use ngrok for local OAuth development",
      context:
        "OAuth providers require publicly accessible callback URLs, which localhost cannot provide during development.",
      decision:
        "Use ngrok to expose the local development server to the internet for OAuth callback handling. This allows testing OAuth flows end-to-end in development without deploying to a staging environment."
    }
  ]

  @doc "Returns the list of pre-made technology decisions."
  def premade_decisions, do: @premade_decisions

  @doc """
  Generate the orchestration prompt for the technical strategy session.

  Reads architecture overview, project deps, existing decisions, and story
  titles, then builds a prompt instructing the agent to write pre-made
  decisions, identify new topics, research them, build knowledge, and
  bootstrap the project.

  Returns {:ok, prompt_text}
  """
  def command(scope, _session, _opts \\ []) do
    env = scope.environment
    project = scope.active_project

    component_count = Components.count_components(scope)
    mix_exs = read_mix_exs(env)
    existing_decisions = list_existing_decisions(env)
    story_titles = list_story_titles(scope)
    missing_premade = missing_premade_decisions(existing_decisions)

    prompt =
      build_prompt(
        project,
        component_count,
        mix_exs,
        existing_decisions,
        story_titles,
        missing_premade
      )

    {:ok, prompt}
  end

  @doc """
  Validate all research topics and pre-made decisions are complete.

  Checks:
  1. All pre-made decisions have ADR files
  2. All research prompt files have completed ResearchTopic validation
  3. The decisions index exists and references all topics
  4. Non-pre-made decided topics have knowledge entries

  Returns:
  - {:ok, :valid} if all checks pass
  - {:ok, :invalid, feedback} if anything is incomplete
  """
  def evaluate(scope, session, _opts \\ []) do
    env = scope.environment

    topics = list_research_topics(env)
    index_exists = decisions_index_exists?(env)
    existing_decisions = list_existing_decisions(env)
    missing_premade = missing_premade_decisions(existing_decisions)
    missing_knowledge = missing_knowledge_entries(env, existing_decisions)

    Logger.info(
      "[TechnicalStrategy] evaluate: #{length(topics)} topic(s), " <>
        "#{length(missing_premade)} missing pre-made, index_exists=#{index_exists}"
    )

    all_clear =
      Enum.empty?(topics) and index_exists and
        Enum.empty?(missing_premade) and Enum.empty?(missing_knowledge)

    if all_clear do
      {:ok, :valid}
    else
      evaluate_all(scope, session, topics, index_exists, missing_premade, missing_knowledge)
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

  defp premade_topics do
    Enum.map(@premade_decisions, & &1.topic)
  end

  defp missing_premade_decisions(existing_decisions) do
    Enum.reject(@premade_decisions, fn d -> d.topic in existing_decisions end)
  end

  defp missing_knowledge_entries(env, existing_decisions) do
    premade = premade_topics()

    existing_decisions
    |> Enum.reject(&(&1 in premade))
    |> Enum.filter(fn topic ->
      case Environments.glob(env, "#{@knowledge_dir}/#{topic}/**") do
        files when is_list(files) and files != [] -> false
        _ -> true
      end
    end)
  end

  # ============================================================================
  # Prompt Building
  # ============================================================================

  defp build_prompt(
         project,
         component_count,
         mix_exs,
         existing_decisions,
         story_titles,
         missing_premade
       ) do
    sections =
      [
        build_header(project),
        build_architecture_section(component_count),
        build_deps_section(mix_exs),
        build_existing_decisions_section(existing_decisions),
        build_premade_decisions_section(missing_premade),
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

  defp build_premade_decisions_section([]), do: nil

  defp build_premade_decisions_section(missing_premade) do
    records =
      Enum.map_join(missing_premade, "\n\n", fn d ->
        """
        ### `#{d.topic}`

        Write to `#{@decisions_dir}/#{d.topic}.md`:

        ```markdown
        # #{d.title}

        ## Status
        Accepted (pre-made)

        ## Context
        #{d.context}

        ## Decision
        #{d.decision}

        ## Consequences
        This is a pre-made decision for the standard CodeMySpec stack.
        ```\
        """
      end)

    """
    ## Pre-made Decisions to Write

    The following technology decisions are pre-made and must be written as decision
    records **before** identifying topics that need research. Write each one exactly
    as shown — do not research alternatives for these.

    #{records}
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

    ### Step 1: Write Pre-made Decisions

    If the "Pre-made Decisions to Write" section above lists any decisions, write
    each one as a decision record now. These are standard stack choices — copy them
    exactly as shown, then add each to the decisions index.

    ### Step 2: Identify Topics

    Analyze the architecture, stories, and current dependencies to identify technology
    decisions that need to be made. Skip topics already covered by pre-made or
    existing decisions. Common categories include:

    - **Testing:** Integration test framework, E2E approach, test data strategy
    - **Deployment:** Hosting, CI/CD, release strategy
    - **Infrastructure:** Caching, background jobs, file storage
    - **Integrations:** Third-party APIs, payment processing, auth providers

    ### Step 3: Write Research Prompts

    For each topic you identify, write a freeform research prompt to
    `docs/status/research/{topic}.md`. The filename becomes the topic name.

    Example: `docs/status/research/wallaby.md` might contain:
    ```
    Research Wallaby for browser-based integration testing of Phoenix LiveView.
    Compare with alternatives like Hound. Consider CI setup requirements.
    ```

    ### Step 4: Research Each Topic

    For each research prompt file, invoke the **researcher** subagent
    (`@"CodeMySpec:researcher (agent)"`) to:
    - Search documentation and community resources
    - Evaluate options against project requirements
    - Write a decision record to `docs/architecture/decisions/{topic}.md`

    ### Step 5: Build Knowledge Base

    For each **researched** (non-pre-made) topic that now has a decision record,
    invoke the **researcher** subagent to build knowledge entries in
    `#{@knowledge_dir}/{topic}/`. Each topic should have at least one knowledge
    file covering setup, configuration, and usage patterns relevant to this project.

    Do **not** build knowledge entries for pre-made decisions — those are
    well-known technologies that don't need project-specific documentation.

    ### Step 6: Update the Index

    Ensure `#{@decisions_index}` exists and lists **all** decision records
    (both pre-made and researched) with their status.

    ### Step 7: Bootstrap

    Now that all decisions are made, configure the project:

    1. **Add libraries** — add any newly decided dependencies to `mix.exs` and
       run `mix deps.get`
    2. **Configure** — add necessary configuration to `config/config.exs`,
       `config/dev.exs`, `config/test.exs`, and `config/runtime.exs` as needed
    3. **Wire up** — update `application.ex` if new supervision trees or
       workers are needed, create any required initialization modules
    4. **Smoke test** — write a small test (e.g., in `test/smoke_test.exs`)
       that verifies the newly added libraries load and basic functionality works

    ### Step 8: Stop

    When all topics have been researched, knowledge built, and the project
    bootstrapped, stop the session so validation can check your work.
    """
  end

  # ============================================================================
  # Evaluation
  # ============================================================================

  defp evaluate_all(scope, session, topics, index_exists, missing_premade, missing_knowledge) do
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

    all_clear = Enum.empty?(incomplete) and index_exists and Enum.empty?(missing_premade) and Enum.empty?(missing_knowledge)

    if all_clear do
      {:ok, :valid}
    else
      feedback =
        build_evaluate_feedback(incomplete, index_exists, missing_premade, missing_knowledge)

      {:ok, :invalid, feedback}
    end
  end

  defp build_child_session(session, topic) do
    %{
      project: Map.get(session, :project),
      state: %{"topic" => topic}
    }
  end

  defp build_evaluate_feedback(incomplete_topics, index_exists, missing_premade, missing_knowledge) do
    parts = []

    parts =
      if index_exists do
        parts
      else
        ["- Decisions index not found at `#{@decisions_index}`" | parts]
      end

    parts =
      Enum.reduce(missing_premade, parts, fn d, acc ->
        ["- Pre-made decision \"#{d.topic}\" has no decision record" | acc]
      end)

    parts =
      Enum.reduce(incomplete_topics, parts, fn {topic, _status}, acc ->
        ["- Topic \"#{topic}\" is incomplete" | acc]
      end)

    parts =
      Enum.reduce(missing_knowledge, parts, fn topic, acc ->
        ["- Topic \"#{topic}\" has no knowledge entries in `#{@knowledge_dir}/#{topic}/`" | acc]
      end)

    issue_list = parts |> Enum.reverse() |> Enum.join("\n")

    """
    Technical strategy is incomplete:

    #{issue_list}

    Address the remaining items and stop the session again.
    """
  end
end
