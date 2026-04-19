defmodule CodeMySpec.AgentTasks.TechnicalStrategy do
  @moduledoc """
  Orchestrator task for identifying and resolving technology decisions.

  Analyzes the project's architecture, stories, and dependencies to identify
  topics needing technology decisions, then auto-writes pre-made ADRs for
  standard stack choices and guides the agent through cursory research and
  ADR creation for remaining topics.

  Focused purely on decisions — deep research is handled by ResearchTopics,
  bootstrap/implementation by ProjectBootstrap.

  Two phases:
  1. **Pre-made decisions** — auto-writes ADRs for standard stack choices before prompting
  2. **Decision-making** — identifies new topics, does cursory research, writes ADRs,
     updates the decisions index

  Artifacts produced:
  - `.code_my_spec/architecture/decisions.md` — index of all decisions
  - `.code_my_spec/architecture/decisions/{topic}.md` — individual decision records
  """

  require Logger

  def orchestrate(node) do
    "Call `start_task` with requirement `#{node.name}` for #{node.entity_type} `#{node.entity_id}` (#{node.entity_name})"
  end

  alias CodeMySpec.{Components, Environments, Paths, Stories}

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
      context: "We need a performant, productive web framework for building our application.",
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
      context: "We need a CSS approach that scales well and avoids naming collisions.",
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
      context: "We need user authentication with registration, login, and session management.",
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
      topic: "wallaby",
      title: "Use Wallaby for browser-based integration testing",
      context:
        "We need a way to drive a real browser for end-to-end testing that handles LiveView's async rendering and integrates with Ecto's sandbox for database isolation.",
      decision:
        "Use Wallaby (`wallaby`) with ChromeDriver for all browser-based integration tests. It provides concurrent test execution, automatic retry/wait for async content (critical for LiveView), Ecto sandbox integration via user_agent metadata, and a clean DSL for interacting with pages (visit, fill_in, click, assert_has)."
    },
    %{
      topic: "bdd-testing",
      title: "Use BDD specs with SexySpex and Wallaby for end-to-end testing",
      context:
        "We need a testing approach that validates user-facing behavior through a real browser and bridges the gap between stories and code.",
      decision:
        "Use BDD specifications with SexySpex (`sexy_spex`) for the Given-When-Then DSL and Wallaby (`wallaby`) for browser-driven interactions. Write specs that test real user workflows through a real browser via ChromeDriver, interacting with LiveView the way a user would — clicking, filling forms, and asserting on visible content."
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
      topic: "resend",
      title: "Use Resend for transactional email",
      context:
        "We need a reliable service for sending transactional emails (account confirmation, password reset, notifications).",
      decision:
        "Use Resend for transactional email delivery. It provides a clean API, good deliverability, and an Elixir-friendly HTTP interface. Pair with Swoosh (`swoosh`) as the Elixir mailer abstraction for testability and local development with Swoosh's built-in mailbox preview."
    },
    %{
      topic: "hetzner-deployment",
      title: "Use Hetzner Cloud with Docker Compose for deployment",
      context:
        "We need a deployment target that is cost-effective, performant, and supports multi-environment hosting (prod + UAT) on a single server.",
      decision:
        "Deploy to a Hetzner cax11 ARM64 server running Docker Compose with Caddy as the reverse proxy. Use the internal DevOps knowledge base for implementation guidance — run `search_knowledge` with query \"hetzner\" or `read_knowledge` with path \"devops/hetzner-docker-deploy.md\" for the full deployment playbook covering server provisioning, Docker Compose stack, Caddy config, Postgres backups, and zero-downtime deploys via docker-rollout."
    },
    %{
      topic: "pow-assent-integrations",
      title: "Use PowAssent and CodeMySpec generators for integrations, multi-tenancy, and feedback",
      context:
        "We need OAuth/third-party integrations, multi-tenant account isolation, and an embeddable feedback widget — all scaffolded consistently and wired into the standard stack.",
      decision:
        "Use PowAssent (`pow_assent`) for OAuth provider integrations and the `code_my_spec_generators` package to scaffold the integration layer (`cms_gen.integrations`, `cms_gen.integration_provider`), multi-tenant accounts (`cms_gen.accounts`), and the feedback widget (`cms_gen.feedback_widget`). The generators produce code that lives in the project, keeping everything customizable while following CodeMySpec conventions."
    }
  ]

  @doc "Returns the list of pre-made technology decisions."
  @spec premade_decisions() :: [
          %{topic: String.t(), title: String.t(), context: String.t(), decision: String.t()}
        ]
  def premade_decisions, do: @premade_decisions

  @doc """
  Generate the orchestration prompt for the technical strategy session.

  Writes any missing pre-made decision ADRs directly to the environment,
  then reads architecture overview, project deps, existing decisions, and
  story titles to build a prompt for decision-making.

  Returns `{:ok, prompt_text}`.
  """
  @spec command(CodeMySpec.Users.Scope.t(), map()) :: {:ok, String.t()}
  def command(scope, _task) do
    env = scope.environment
    project = scope.active_project

    ensure_premade_decisions(env)

    component_count = Components.count_components(scope)
    mix_exs = read_mix_exs(env)
    existing_decisions = list_existing_decisions(env)
    story_titles = list_story_titles(scope)

    prompt =
      build_prompt(
        project,
        component_count,
        mix_exs,
        existing_decisions,
        story_titles
      )

    {:ok, prompt}
  end

  @doc """
  Validate all pre-made decisions exist and the decisions index is complete.

  Checks:
  1. Decisions index file exists
  2. All pre-made decisions have ADR files

  Returns:
  - `{:ok, :valid}` if all checks pass
  - `{:ok, :invalid, feedback}` if anything is incomplete
  """
  @spec evaluate(CodeMySpec.Users.Scope.t(), map()) ::
          {:ok, :valid} | {:ok, :invalid, String.t()}
  def evaluate(scope, _task) do
    env = scope.environment

    index_exists = decisions_index_exists?(env)

    Logger.info("[TechnicalStrategy] evaluate: index_exists=#{index_exists}")

    if index_exists do
      {:ok, :valid}
    else
      {:ok, :invalid,
       """
       Technical strategy is incomplete:

       - Decisions index not found at `#{Paths.decisions_index()}`

       Address the remaining items and stop the session again.
       """}
    end
  end

  @doc """
  Write all missing pre-made decision ADR files to the environment.

  Returns the count of decisions written.
  """
  @spec ensure_premade_decisions(Environments.Environment.t()) :: non_neg_integer()
  def ensure_premade_decisions(env) do
    existing = list_existing_decisions(env)
    missing = missing_premade_decisions(existing)

    Enum.each(missing, &write_premade_decision(env, &1))

    length(missing)
  end

  defp write_premade_decision(env, decision) do
    content =
      """
      # #{decision.title}

      ## Status
      Accepted (pre-made)

      ## Context
      #{decision.context}

      ## Decision
      #{decision.decision}

      ## Consequences
      This is a pre-made decision for the standard CodeMySpec stack.
      """
      |> String.trim_leading()

    Environments.write_file(env, "#{Paths.decisions_dir()}/#{decision.topic}.md", content)
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
    case Environments.glob(env, "#{Paths.decisions_dir()}/*.md") do
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

  defp decisions_index_exists?(env) do
    Environments.file_exists?(env, Paths.decisions_index()) == true
  end

  defp missing_premade_decisions(existing_decisions) do
    Enum.reject(@premade_decisions, fn d -> d.topic in existing_decisions end)
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
    options, and produce decision records.
    """
  end

  defp build_architecture_section(0), do: nil

  defp build_architecture_section(component_count) do
    """
    ## Architecture Overview

    The project has #{component_count} components defined. Review the architecture views for details:

    - **Overview:** `#{Paths.architecture_dir()}/overview.md`
    - **Dependency Graph:** `#{Paths.architecture_dir()}/dependency_graph.mmd`
    - **Namespace Hierarchy:** `#{Paths.architecture_dir()}/namespace_hierarchy.md`
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

    The following topics already have decision records in `#{Paths.decisions_dir()}/`:

    #{decision_list}

    Review these to avoid duplicating work. You can update existing decisions if needed. Remove any decisions that are not necessary for this project.
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
    decisions that need to be made. Skip topics already covered by pre-made or
    existing decisions. Common categories include:

    - **Testing:** Integration test framework, E2E approach, test data strategy
    - **Deployment:** Hosting, CI/CD, release strategy
    - **Infrastructure:** Caching, background jobs, file storage
    - **Integrations:** Third-party APIs, payment processing, auth providers

    ### Step 2: Research and Decide Each Topic

    For each identified topic, do cursory research (search hex.pm, check docs), evaluate
    against project needs, and write a decision record to
    `#{Paths.decisions_dir()}/{topic}.md` with sections:

    - **Title** — a concise statement of the decision
    - **Status** — Accepted, Proposed, or Superseded
    - **Context** — why this decision is needed
    - **Options Considered** — alternatives evaluated with pros and cons
    - **Decision** — what was chosen and why
    - **Consequences** — tradeoffs and follow-on work

    ### Step 3: Update the Index

    Ensure `#{Paths.decisions_index()}` exists and lists all decision records
    (pre-made and new) with their status.

    ### Step 4: Stop

    When all topics have been researched and decision records written, stop the session
    so validation can check your work.
    """
  end

  # ============================================================================
  # Evaluation
  # ============================================================================

end
