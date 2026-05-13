defmodule CodeMySpecSpex.ProjectStateFixtures do
  @moduledoc """
  Composable fixtures for advancing project state past the serial chain
  of project-level requirements so component-level requirements become
  actionable.

  Background: `RequirementGraph` clamps satisfaction along a chain —
  project_setup → personas_complete → stories_exist → technical_strategy
  → architecture_designed → ... Until that chain clears, the actionable
  wave is dominated by project-level work and component child-phase
  requirements stay invisible.

  These fixtures let a spex advance to exactly the state it needs:

      given_ "the project chain is fully kicked off", context do
        ProjectStateFixtures.apply_project_kickoff(context)
      end

  ## Composability

  Each `apply_*` function takes and returns a context map, so they
  chain. `apply_project_kickoff/1` is the convenience that bundles
  every step. Reach for the individual functions when a spex only
  needs *part* of the chain satisfied.

  ## What's NOT covered

  - `stories_exist` — caller creates stories with the priorities and
    component-links the test needs.
  - Per-component artifacts (spec/impl/review files for HighContext et al.)
    — caller writes those, since the topology under test is what each
    spec is specifically about.
  - `architecture_designed`'s orphan-component check — this iterates
    live DB components, so each component the caller syncs must be
    story-linked (directly or transitively) before `get_next_requirement`
    fires.
  """

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias Anubis.Server.Frame
  alias CodeMySpec.AgentTasks.Setup
  alias CodeMySpec.Environments
  alias CodeMySpec.McpServers.BddRules.Tools.AddRule
  alias CodeMySpec.McpServers.BddRules.Tools.AddScenario
  alias CodeMySpec.McpServers.Personas.Tools.CreatePersona
  alias CodeMySpec.McpServers.Personas.Tools.LinkPersonaToStory
  alias CodeMySpecSpex.Fixtures
  alias CodeMySpecSpex.TaskResponseHelpers

  @endpoint CodeMySpecLocalWeb.Endpoint

  @all_setup_steps [
    Setup.ApplicationInWeb,
    Setup.CodemyspecDeps,
    Setup.Compilers,
    Setup.SpexConfig,
    Setup.TestBoundaries,
    Setup.TestSupportNamespace,
    Setup.SpexCase,
    Setup.ProjectStructure,
    Setup.AgentsMd,
    Setup.Rules,
    Setup.CredoChecks,
    Setup.ClaudeMd
  ]

  @doc """
  Bundle of every project-level satisfier in this module. Equivalent to
  piping a context through every individual `apply_*` function.

  After this returns, the project-level chain (project_setup, personas_complete,
  technical_strategy, code_generation, qa_integration_plan,
  architecture_designed, spex_boundary_ready, qa_setup, qa_preflight,
  qa_journey_*) is satisfied. The caller is responsible for `stories_exist`
  (creating stories) and component artifacts.

  Produces `context.persona_slug` and `context.persona_id`.
  """
  @spec apply_project_kickoff(map(), keyword()) :: map()
  def apply_project_kickoff(context, opts \\ []) do
    context
    |> apply_project_setup_steps()
    |> apply_technical_strategy()
    |> apply_code_generation()
    |> apply_qa_integration_plan()
    |> apply_architecture(opts)
    |> apply_spex_boundary_ready()
    |> apply_qa_setup_preflight()
    |> apply_journey_artifacts()
    |> apply_persona()
  end

  @doc """
  Satisfies `project_setup` by writing every setup-step artifact via
  the canonical setup-step fixture path. Also seeds
  `.code_my_spec/config.yml` with `infrastructure_paths` so framework
  boilerplate that sync picks up (e.g., `MyAppWeb.Application`) is
  tagged as infrastructure and skipped by `architecture_designed`'s
  orphan check.

  The config.yml is written to the real cwd (not the in-memory env)
  because `Scope.read_local_config/1` reads via `YamlElixir.read_from_file/1`,
  which only sees actual disk.
  """
  @spec apply_project_setup_steps(map()) :: map()
  def apply_project_setup_steps(context) do
    Fixtures.satisfy_setup_steps(context.environment, @all_setup_steps)

    config_path = Path.join([context.scope.cwd, ".code_my_spec", "config.yml"])
    File.mkdir_p!(Path.dirname(config_path))

    File.write!(
      config_path,
      CodeMySpec.McpServers.Bootstrap.Content.infrastructure_paths_yaml("MyApp")
    )

    context
  end

  @doc "Satisfies `technical_strategy` by writing the decisions index."
  @spec apply_technical_strategy(map()) :: map()
  def apply_technical_strategy(context) do
    Fixtures.with_decisions_index(context.environment)
    context
  end

  @doc "Satisfies `code_generation` by writing a populated generator script."
  @spec apply_code_generation(map()) :: map()
  def apply_code_generation(context) do
    Fixtures.with_full_script(context.environment)
    context
  end

  @doc "Satisfies `qa_integration_plan` by writing a verified integration spec."
  @spec apply_qa_integration_plan(map(), String.t()) :: map()
  def apply_qa_integration_plan(context, provider \\ "stripe") do
    Fixtures.with_verified_integration_spec(context.environment, provider)
    context
  end

  @doc """
  Satisfies `architecture_designed` by writing a generic proposal.md.

  The orphan-component half of the check (every non-infrastructure
  component must be transitively story-linked) is evaluated live
  against the DB at check time — the caller must ensure their
  components are story-linked before `get_next_requirement` fires.

  Options:
    * `:proposal_content` — override the proposal.md body (default: a
      generic context proposal).
  """
  @spec apply_architecture(map(), keyword()) :: map()
  def apply_architecture(context, opts \\ []) do
    proposal_content =
      Keyword.get_lazy(opts, :proposal_content, fn ->
        Fixtures.proposal_with_context(
          "MyApp",
          "Reservations",
          "Generic bounded context for the project kickoff fixture."
        )
      end)

    Fixtures.with_proposal(context.environment, proposal_content)
    context
  end

  @doc """
  Satisfies `spex_boundary_ready` by writing the framework Credo checks,
  the fixtures bridge, and the project BDD plan into the env.
  """
  @spec apply_spex_boundary_ready(map()) :: map()
  def apply_spex_boundary_ready(context) do
    :ok = CodeMySpecSpex.SpexBoundaryArtifactHelpers.write_baseline_artifacts(context.environment)
    context
  end

  @doc "Satisfies `qa_setup` and `qa_preflight` by writing their plan files."
  @spec apply_qa_setup_preflight(map()) :: map()
  def apply_qa_setup_preflight(context) do
    env = context.environment
    :ok = Environments.write_file(env, ".code_my_spec/qa/plan.md", qa_plan_content())
    :ok = Environments.write_file(env, ".code_my_spec/qa/preflight.md", qa_preflight_content())
    context
  end

  @doc """
  Satisfies `qa_journey_plan`, `qa_journey_execute`, and `qa_journey_wallaby`
  by writing the three journey artifacts.
  """
  @spec apply_journey_artifacts(map()) :: map()
  def apply_journey_artifacts(context) do
    env = context.environment

    :ok =
      Environments.write_file(env, ".code_my_spec/qa/journey_plan.md", qa_journey_plan_content())

    :ok =
      Environments.write_file(
        env,
        ".code_my_spec/qa/journey_result.md",
        qa_journey_result_content()
      )

    :ok = Environments.write_file(env, "test/e2e/sample_journey_test.exs", wallaby_content())
    context
  end

  @doc """
  Satisfies `personas_complete` by creating a persona via the MCP tool
  and writing the persona's summary.md and sources.md.

  Produces `context.persona_slug` and `context.persona_id`.
  """
  @spec apply_persona(map(), keyword()) :: map()
  def apply_persona(context, opts \\ []) do
    slug = Keyword.get(opts, :slug, "founder")
    name = Keyword.get(opts, :name, "Founder")
    headline = Keyword.get(opts, :headline, "Solo founder shipping a product")

    frame = %Frame{assigns: %{current_scope: context.scope}}

    {:reply, response, _frame} =
      CreatePersona.execute(%{slug: slug, name: name, headline: headline}, frame)

    persona_id =
      case Regex.run(~r/\bid: `([^`]+)`/, TaskResponseHelpers.response_text(response)) do
        [_, id] -> id
        _ -> nil
      end

    :ok =
      Environments.write_file(
        context.environment,
        ".code_my_spec/personas/#{slug}/summary.md",
        persona_summary_content()
      )

    :ok =
      Environments.write_file(
        context.environment,
        ".code_my_spec/personas/#{slug}/sources.md",
        persona_sources_content()
      )

    Map.merge(context, %{persona_slug: slug, persona_id: persona_id})
  end

  @doc """
  Satisfies `three_amigos_complete` on a specific story by linking a
  persona and adding one `:happy_path` + one `:failure_path` scenario
  (both kind-tagged, which the BddRulesChecker requires).

  Defaults pick canonical values; override `:rule_statement`,
  `:happy_*`, `:failure_*` to taste.

  Returns `:ok`. Story-scoped — call once per story.
  """
  @spec apply_three_amigos_for_story(map(), term(), keyword()) :: :ok
  def apply_three_amigos_for_story(scope, story, opts \\ []) do
    persona_id = Keyword.fetch!(opts, :persona_id)

    rule_statement =
      Keyword.get(
        opts,
        :rule_statement,
        "Default rule statement for #{story.title || "the story"}"
      )

    happy_title = Keyword.get(opts, :happy_title, "Happy path")

    happy_body =
      Keyword.get(
        opts,
        :happy_body,
        "Given the user opens the page\nWhen they perform the action\nThen the action succeeds"
      )

    failure_title = Keyword.get(opts, :failure_title, "Failure path")

    failure_body =
      Keyword.get(
        opts,
        :failure_body,
        "Given the user is unauthorized\nWhen they attempt the action\nThen they are denied"
      )

    frame = %Frame{assigns: %{current_scope: scope}}

    {:reply, _response, _frame} =
      LinkPersonaToStory.execute(%{persona_id: persona_id, story_id: story.id}, frame)

    {:reply, _response, _frame} =
      AddRule.execute(%{story_id: story.id, statement: rule_statement}, frame)

    {:reply, _response, _frame} =
      AddScenario.execute(
        %{
          story_id: story.id,
          rule_statement: rule_statement,
          kind: "happy_path",
          title: happy_title,
          body: happy_body
        },
        frame
      )

    {:reply, _response, _frame} =
      AddScenario.execute(
        %{
          story_id: story.id,
          rule_statement: rule_statement,
          kind: "failure_path",
          title: failure_title,
          body: failure_body
        },
        frame
      )

    :ok
  end

  @doc """
  Satisfies `bdd_specs_exist` and `bdd_specs_passing` on a story by
  writing a passing-stub BDD spec file at the canonical path the
  harness derives from `(story_id, criterion_id)`. Requires the
  story to have at least one criterion.

  Returns `:ok`. Re-syncs the working dir so the file is registered
  with role `:bdd_spec`.
  """
  @spec apply_bdd_spec_for_story(map(), term()) :: :ok
  def apply_bdd_spec_for_story(context, story) do
    [criterion | _] = story.criteria

    bdd_path = Fixtures.spec_file_path(story, criterion)

    :ok =
      Environments.write_file(
        context.environment,
        bdd_path,
        passing_bdd_spec_content(story, criterion)
      )

    {:ok, sync_live, _html} =
      live(context.conn, "/projects/#{context.project.name}/files")

    sync_live |> element("button[phx-click='sync']") |> render_click()

    :ok
  end

  @doc """
  Satisfies `qa_complete` on a story by writing the qa brief and
  result files at `.code_my_spec/qa/<story_id>/{brief,result}.md`.
  """
  @spec apply_qa_complete_for_story(map(), term()) :: :ok
  def apply_qa_complete_for_story(context, story) do
    env = context.environment
    story_id = story.id

    :ok =
      Environments.write_file(env, ".code_my_spec/qa/#{story_id}/brief.md", qa_brief_content())

    :ok =
      Environments.write_file(env, ".code_my_spec/qa/#{story_id}/result.md", qa_result_content())

    :ok
  end

  @doc """
  Clears the full story-level chain on a single story so the actionable
  wave can march past it and reach component-level work.

  Bundles `apply_three_amigos_for_story`, `apply_bdd_spec_for_story`,
  and `apply_qa_complete_for_story`. Caller must already have a
  persona created (e.g., via `apply_persona/2`) and pass its id.
  """
  @spec apply_story_chain_complete(map(), term(), keyword()) :: :ok
  def apply_story_chain_complete(context, story, opts) do
    :ok = apply_three_amigos_for_story(context.scope, story, opts)
    :ok = apply_bdd_spec_for_story(context, story)
    :ok = apply_qa_complete_for_story(context, story)
    :ok
  end

  # -- Inline content helpers --

  defp qa_plan_content do
    """
    # QA Plan

    ## App Overview

    Phoenix LiveView application running on port 4003 with session-based auth.

    ## Tools Registry

    ### web tool

    Use `web` for LiveView pages with `--profile qa`.

    ### curl

    Use `curl` for controller/JSON endpoints — see `.code_my_spec/qa/scripts/auth.sh`.

    ## Seed Strategy

    Run `mix run priv/repo/qa_seeds.exs` to seed the QA fixture project.
    """
  end

  defp qa_preflight_content do
    """
    # QA Preflight

    App-level integration verification complete. No outstanding system issues.
    """
  end

  defp qa_journey_plan_content do
    """
    # QA Journey Plan

    ## Journeys

    ### Empty-state user reaches a working app

    - **Role:** new user
    - **Steps:** register → confirm → create account → create project
    - **Expected outcome:** user lands on /app/projects with active project

    ## Prerequisites

    - Server running on port 4003
    - Seed scripts run
    """
  end

  defp qa_journey_result_content do
    """
    # QA Journey Result

    ## Status

    pass

    ## Journey Results

    ### Empty-state user reaches a working app

    All steps executed successfully — user reached /app/projects with active project.
    """
  end

  defp wallaby_content do
    """
    defmodule MyApp.E2E.SampleJourneyTest do
      use ExUnit.Case
      @moduletag :pending
    end
    """
  end

  defp persona_summary_content do
    """
    # Founder

    ## Role

    Solo technical founder shipping a SaaS product without a team.

    ## Goals

    - Ship features quickly without sacrificing quality
    - Avoid the "fiddle tax" of repetitive scaffolding work
    - Use AI as labor to amplify output

    ## Pain Points

    - Manual project setup eats hours per project
    - Switching between strategy and implementation breaks flow
    - Existing harnesses don't match how solo founders actually work

    ## Context

    Operates as a one-person product team — design, code, marketing, support all on one plate.

    ## Decision Drivers

    - Time-to-shipping
    - Predictability of the build loop
    - Trust in AI-generated artifacts

    ## Evidence

    - Internal interviews with five solo founders running similar businesses
    - Personal experience building three SaaS products solo
    """
  end

  defp persona_sources_content do
    """
    - Internal interview log: 2026-04-15 with founder of Acme SaaS
    - Personal product log: 2025-12 through 2026-04
    - Public Twitter threads from solo founders documenting their build loops
    """
  end

  defp passing_bdd_spec_content(story, criterion) do
    """
    defmodule CodeMySpecSpex.Story#{story.id}.Criterion#{criterion.id}Spex do
      @moduledoc \"\"\"
      Story #{story.id} — #{story.title}
      Criterion #{criterion.id} — #{criterion.description}
      \"\"\"

      use CodeMySpecSpex.Case

      spex "#{story.title}" do
        scenario "the criterion holds" do
          then_ "the placeholder assertion passes" do
            assert true
            :ok
          end
        end
      end
    end
    """
  end

  defp qa_brief_content do
    """
    # QA Brief

    ## Tool

    web

    ## Auth

    Run `.code_my_spec/qa/scripts/auth.sh` and copy the session cookie.

    ## Seeds

    `mix run priv/repo/qa_seeds.exs`

    ## What to test

    - Visit the surface and verify it renders
    - Exercise the happy path and verify success
    - Exercise a failure path and verify the rejection

    ## Result Path

    .code_my_spec/qa/<story_id>/result.md
    """
  end

  defp qa_result_content do
    """
    # QA Result

    ## Status

    pass

    ## Scenarios

    ### Surface renders

    Visited the surface — page rendered with placeholder content.
    """
  end
end
