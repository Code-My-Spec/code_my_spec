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

  alias Anubis.Server.Frame
  alias CodeMySpec.AgentTasks.Setup
  alias CodeMySpec.ExecutionContexts
  alias CodeMySpec.ToolLibrary
  alias CodeMySpecSpex.Fixtures
  alias CodeMySpecSpex.StoryHelpers

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

  @doc false
  # Put what was just written in front of the graph.
  #
  # These fixtures exist to leave a requirement satisfied, and a file on disk
  # that the graph has never seen satisfies nothing. In production
  # the harness manifest carries changed paths; there is no harness in a spex,
  # so the fixture does it.
  #
  # It used to happen by accident. `GetNextRequirement` opened with a full
  # `FileSync.sync/2`, so any file written before the agent asked was picked up
  # on the way to the graph — which made a read path responsible for a write's
  # visibility, and meant admission (`Agents.Work.graph_work?/2`, no sync) and
  # the agent's own question answered from two different graphs. Issue
  # c83c5b58. The sync is gone from there, so it belongs here.
  @spec synced(map()) :: map()
  def synced(%{scope: scope} = context) do
    :ok = Fixtures.sync_files(scope)
    context
  end

  def synced(context), do: context

  @doc """
  Bundle of every project-level satisfier in this module. Equivalent to
  piping a context through every individual `apply_*` function.

  After this returns, the project-level chain (project_setup, personas_complete,
  technical_strategy, code_generation, qa_integration_plan,
  architecture_designed, spex_boundary_ready, qa_setup, qa_journey_*) is
  satisfied. The caller is responsible for `stories_exist`
  (creating stories) and component artifacts.

  Produces `context.persona_slug` and `context.persona_id`.

  ## `qa_setup: false`

  Leaves `.code_my_spec/qa/plan.md` unwritten, so `qa_setup` stays open and the
  QA role has exactly one thing waiting.

  Here because "the graph holds work for one role and not another" is a premise
  several criteria need and none could state. Reaching for QA's other
  requirement, `qa_complete`, means standing up the whole story chain — three
  amigos, specs green on a fresh run, code on the running copy — and a scenario
  that has to build all of that to say "QA has work" is testing the chain
  rather than the routing. `qa_setup` is a `path_exists` check on a project
  node, so not writing one file says the same thing about the graph.
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
    |> maybe_apply_qa_setup(Keyword.get(opts, :qa_setup, true))
    |> apply_journey_artifacts()
    |> apply_persona()
    |> synced()
  end

  defp maybe_apply_qa_setup(context, false), do: context
  defp maybe_apply_qa_setup(context, _), do: apply_qa_setup(context)

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
    # Pass scope (not env) — the Scope overload of satisfy_setup_steps
    # also syncs the seeded files into the Files table, which the
    # individual step checks (e.g. ApplicationInWeb) query directly.
    # The Environment overload only writes files; the DB lookup then
    # finds nothing and the step stays incomplete.
    Fixtures.satisfy_setup_steps(context.scope, @all_setup_steps)

    config_path = Path.join([context.scope.cwd, ".code_my_spec", "config.yml"])
    File.mkdir_p!(Path.dirname(config_path))
    File.write!(config_path, "module_name: MyApp\n")

    context
  end

  @doc "Satisfies `technical_strategy` by writing the decisions index."
  @spec apply_technical_strategy(map()) :: map()
  def apply_technical_strategy(context) do
    Fixtures.with_decisions_index(context.execution_context)
    context
  end

  @doc "Satisfies `code_generation` by writing a populated generator script."
  @spec apply_code_generation(map()) :: map()
  def apply_code_generation(context) do
    Fixtures.with_full_script(context.execution_context)
    context
  end

  @doc """
  Satisfies `devops_setup` by writing a setup record attesting verified
  environments (story 858). The evaluator requires an `## Environments`
  section with live health-check verification — and `prod` unless the
  project opted out via `devops: :uat` (one level below the full-promotion default).
  """
  @spec apply_devops_setup(map()) :: map()
  def apply_devops_setup(context) do
    :ok =
      ExecutionContexts.write_file(context.execution_context, ".code_my_spec/devops/setup.md", """
      # DevOps Setup

      ## Environments

      - uat.example.test — health check verified (200 over TLS)
      - example.test (prod) — health check verified (200 over TLS)

      ## Resilience

      - Nightly pg_dump to the backups bucket (90-day expiry)
      - Uptime monitors: uat.example.test, example.test
      """)

    synced(context)
  end

  @doc """
  Satisfies the story-level `deploy` requirement by writing the story's
  deploy record with a verified promotion (story 858).
  """
  @spec apply_deploy_record(map()) :: map()
  def apply_deploy_record(%{story: story} = context) do
    :ok =
      ExecutionContexts.write_file(
        context.execution_context,
        ".code_my_spec/devops/deploys/story_#{story.id}.md",
        """
        # Deploy — story #{story.id}

        - Version: abc123
        - UAT health check: verified (200 over TLS)
        - Prod health check: verified (200 over TLS)
        """
      )

    synced(context)
  end

  @doc """
  Satisfies the project-level `release` requirement by writing a release
  record whose `## Stories` manifest covers the context's story (story 859).
  Coverage is content-based: an uncovered deploy record reopens the release.
  """
  @spec apply_release_record(map()) :: map()
  def apply_release_record(%{story: story} = context) do
    :ok =
      ExecutionContexts.write_file(
        context.execution_context,
        ".code_my_spec/releases/0.1.0.md",
        """
        # Release 0.1.0

        User-facing notes for the cycle.

        ## Stories

        - story_#{story.id}

        ## Verification

        - Prod health check: verified (200 over TLS)
        - Tag v0.1.0 annotated + GitHub Release published
        """
      )

    synced(context)
  end

  @doc """
  Satisfies `qa_integration_plan` by writing a fully verified integration:
  spec + verify script + index. The graph check delegates to
  `QaIntegrationPlan.evaluate/2`, which requires all three (a lone spec
  file without index/script now yields `:invalid`).
  """
  @spec apply_qa_integration_plan(map(), String.t()) :: map()
  def apply_qa_integration_plan(context, provider \\ "stripe") do
    Fixtures.with_verified_integration(context.execution_context, provider)
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

    Fixtures.with_proposal(context.execution_context, proposal_content)
    context
  end

  @doc """
  Satisfies `spex_boundary_ready` by writing the framework Credo checks,
  the fixtures bridge, and the project BDD plan into the env.
  """
  @spec apply_spex_boundary_ready(map()) :: map()
  def apply_spex_boundary_ready(context) do
    :ok =
      CodeMySpecSpex.SpexBoundaryArtifactHelpers.write_baseline_artifacts(
        context.execution_context
      )

    context
  end

  @doc "Satisfies `qa_setup` by writing the QA plan file."
  @spec apply_qa_setup(map()) :: map()
  def apply_qa_setup(context) do
    env = context.execution_context
    :ok = ExecutionContexts.write_file(env, ".code_my_spec/qa/plan.md", qa_plan_content())
    synced(context)
  end

  @doc """
  Satisfies `qa_journey_plan` and `qa_journey_execute` by writing the two
  journey artifacts.
  """
  @spec apply_journey_artifacts(map()) :: map()
  def apply_journey_artifacts(context) do
    env = context.execution_context

    :ok =
      ExecutionContexts.write_file(
        env,
        ".code_my_spec/qa/journey_plan.md",
        qa_journey_plan_content()
      )

    :ok =
      ExecutionContexts.write_file(
        env,
        ".code_my_spec/qa/journey_result.md",
        qa_journey_result_content()
      )

    synced(context)
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

    created =
      ToolLibrary.run("create_persona", %{slug: slug, name: name, headline: headline}, %{
        scope: context.scope
      })

    persona_id = created_or_existing_persona_id(context.scope, slug, created)

    :ok =
      ExecutionContexts.write_file(
        context.execution_context,
        ".code_my_spec/personas/#{slug}/summary.md",
        persona_summary_content()
      )

    :ok =
      ExecutionContexts.write_file(
        context.execution_context,
        ".code_my_spec/personas/#{slug}/sources.md",
        persona_sources_content()
      )

    Map.merge(context, %{persona_slug: slug, persona_id: persona_id})
  end

  # Idempotent, because the chains call it twice.
  #
  # `create_persona` answers with the id in prose, and this read it out with a
  # regex — which works exactly once. `apply_project_kickoff/2` applies a
  # persona, and `FullSatisfactionFixtures.apply_without_qa_story/1` applies one
  # again; the second call finds the slug taken, answers something the regex
  # does not match, and `persona_id` comes back `nil`.
  #
  # Nothing notices until much later: `apply_three_amigos_for_story/3` passes
  # that nil to `link_persona_to_story`, and the failure is
  # `comparing p.id with nil is forbidden` from inside an Ecto query, four
  # frames down and naming neither the persona nor the fixture that lost it.
  #
  # So the id is read back from the project when the reply does not carry one.
  # A persona that already exists is the same persona; the fixture's job is to
  # guarantee one is there, not to be the one that made it.
  defp created_or_existing_persona_id(scope, slug, created) do
    with {:ok, text} <- created,
         [_, id] <- Regex.run(~r/\bid: `([^`]+)`/, text) do
      id
    else
      _ -> existing_persona_id(scope, slug)
    end
  end

  # Through the tool, not `CodeMySpec.Personas` directly. This module's own
  # rule is bridge fixtures and tools only, and `CodeMySpecSpex` has no
  # boundary dependency on `Personas` — reaching it raises a forbidden
  # reference, which is the boundary doing its job rather than an obstacle.
  defp existing_persona_id(scope, slug) do
    with {:ok, text} <- ToolLibrary.run("get_persona", %{slug: slug}, %{scope: scope}),
         [_, id] <- Regex.run(~r/\bid: `([^`]+)`/, text) do
      id
    else
      _ -> nil
    end
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

    {:ok, _response} =
      ToolLibrary.run(
        "link_persona_to_story",
        %{persona_id: persona_id, story_number: story.number},
        Map.put(frame.assigns, :scope, frame.assigns[:current_scope])
      )

    _response =
      ToolLibrary.run("add_rule", %{story_number: story.number, statement: rule_statement}, %{
        scope: frame.assigns.current_scope
      })

    _response =
      ToolLibrary.run(
        "add_scenario",
        %{
          story_number: story.number,
          rule_statement: rule_statement,
          kind: "happy_path",
          title: happy_title,
          body: happy_body
        },
        Map.put(frame.assigns, :scope, frame.assigns[:current_scope])
      )

    _response =
      ToolLibrary.run(
        "add_scenario",
        %{
          story_number: story.number,
          rule_statement: rule_statement,
          kind: "failure_path",
          title: failure_title,
          body: failure_body
        },
        Map.put(frame.assigns, :scope, frame.assigns[:current_scope])
      )

    # And sealed, because that is what `three_amigos_complete` reads now.
    #
    # Through the same door the product uses rather than by writing the field:
    # `ThreeAmigos.evaluate/2` seals only on a passing check, so a fixture that
    # set the flag directly could seal a story this fixture had left incomplete,
    # and every downstream test would then be built on a state the product
    # cannot produce.
    :ok = CodeMySpecSpex.Fixtures.seal_three_amigos(scope, story)

    :ok
  end

  @doc """
  Satisfies `bdd_specs_exist` on a story by
  writing a passing-stub BDD spec file at the canonical path the
  harness derives from `(story_id, criterion_id)`. Requires the
  story to have at least one criterion.

  Returns `:ok`. Re-syncs the working dir so the file is registered
  with role `:bdd_spec`.
  """
  @spec apply_bdd_spec_for_story(map(), term()) :: :ok
  def apply_bdd_spec_for_story(context, story) do
    story = StoryHelpers.fetch(context.scope, story.id)

    # bdd_specs_covered checks every criterion, not just the first
    # (issue 644279a9) -- three_amigos leaves happy + failure path
    # criteria, and both need a file or the story's chain never clears.
    Enum.each(story.criteria, fn criterion ->
      bdd_path = Fixtures.spec_file_path(story, criterion)

      :ok =
        ExecutionContexts.write_file(
          context.execution_context,
          bdd_path,
          passing_bdd_spec_content(story, criterion)
        )
    end)

    # The sync, not the button — see `synced/1`. `live/2` raises outside a test
    # process, which made every fixture that used it unusable from
    # `mix cms.eval`.
    synced(context)

    :ok
  end

  @doc """
  Satisfies `qa_complete` on a story.

  The `qa_complete` requirement now checks `CodeMySpec.Qa.complete?/2`
  (DB-driven) rather than `result_complete.md` existence. This fixture
  inserts a `QaAttempt` row directly via the schema changeset to mark
  the story's QA as passed. The legacy brief file is still written for
  any backward-compatibility readers, but it no longer gates anything.
  """
  @spec apply_qa_complete_for_story(map(), term()) :: :ok
  def apply_qa_complete_for_story(context, story) do
    env = context.execution_context
    story_id = story.id

    :ok =
      ExecutionContexts.write_file(
        env,
        ".code_my_spec/qa/#{story_id}/brief.md",
        qa_brief_content()
      )

    {:ok, _attempt} =
      Fixtures.passed_qa_attempt(context.scope, story_id: story_id)

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
    - https://example.com/acme-founder-interview — "Acme SaaS founder interview" — accessed 2026-04-15
    - https://example.com/personal-product-log — "Personal product log 2025-12 through 2026-04" — accessed 2026-04-30
    - https://twitter.com/example/solo-builder-threads — "Public Twitter threads from solo founders" — accessed 2026-04-20
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

      spex "#{story.title}", criterion: #{Map.get(criterion, :number) || criterion.id} do
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
end
