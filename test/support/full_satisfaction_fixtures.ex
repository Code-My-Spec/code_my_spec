defmodule CodeMySpecSpex.FullSatisfactionFixtures do
  @moduledoc """
  Composes existing bridge fixtures into a fully-satisfied project state.

  The goal: write enough files (and DB rows via MCP tools) that
  `RequirementGraph.next_actionable/1` returns `[]`. This is the
  "everything is green" end-state — useful for testing rule 7
  (empty-list contract) and any other scenario that needs a known
  fully-satisfied baseline.

  ## What's covered

  Project-level requirements:
  - `project_setup` — via `Fixtures.satisfy_setup_steps/2`
  - `technical_strategy` — via `Fixtures.with_decisions_index/1`
  - `personas_complete` — DB persona via MCP + summary.md + sources.md
  - `code_generation` — via `Fixtures.with_full_script/1`
  - `qa_integration_plan` — via `Fixtures.with_verified_integration_spec/2`
  - `architecture_designed` — via `Fixtures.with_proposal/2`
  - `issues_triaged`, `issues_resolved` — vacuous (no incoming issues)
  - `qa_setup`, `qa_preflight` — write `.code_my_spec/qa/{plan,preflight}.md`
  - `all_bdd_specs_passing` — bdd spec file written + zero spex problems
  - `qa_journey_plan`, `qa_journey_execute`, `qa_journey_wallaby` — files written

  Story-level requirements:
  - `component_linked` — `set_story_component` MCP
  - `three_amigos_complete` — persona linked + rule + criterion (via MCP)
  - `bdd_specs_exist`, `bdd_specs_passing` — bdd spec file + zero spex problems
  - `qa_complete` — `.code_my_spec/qa/<story_id>/{brief,result}.md`

  Component-level requirements (for a single schema component, the
  simplest type — schema_graph: spec_file, spec_valid,
  implementation_file):
  - All three satisfied via `GraphContentFixtures` content + sync.

  ## What's NOT covered

  - `test_spec_alignment` — requires deeper test↔spec function-level
    alignment analysis. Skipped; use `require_unit_tests: false` if
    needed.
  - `tests_passing` for non-schema components — requires zero test
    problems. Vacuously satisfied if no test problems are recorded.

  ## Usage

      given_ :fully_satisfied_project
      # context now has :scope, :environment, :project, :story, :component
      # and next_actionable should return []
  """

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias Anubis.Server.Frame
  alias CodeMySpec.AgentTasks.Setup
  alias CodeMySpec.Environments
  alias CodeMySpec.McpServers.Personas.Tools.CreatePersona
  alias CodeMySpec.McpServers.Personas.Tools.LinkPersonaToStory
  alias CodeMySpec.McpServers.Stories.Tools.AddCriterion
  alias CodeMySpecSpex.Fixtures
  alias CodeMySpecSpex.GraphContentFixtures, as: Content
  alias CodeMySpecSpex.StoryHelpers
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
    Setup.IgnoredPaths,
    Setup.AgentsMd,
    Setup.Rules,
    Setup.CredoChecks,
    Setup.ClaudeMd
  ]

  @doc """
  Apply all satisfaction layers to the test context. Returns a
  context with `:component`, `:story`, and `:persona_slug` set.

  Composes:
  1. Project-level setup files
  2. Project-level artifact files (technical strategy, code gen, etc.)
  3. Component spec/impl files + sync
  4. Story creation + linking + criteria + persona
  5. BDD spec file for the story
  6. QA artifact files (plan, preflight, journey, brief, result)

  Each step uses the existing bridge fixtures or MCP tools — no
  context-fn calls, no Repo writes.
  """
  @spec apply(map()) :: map()
  def apply(context) do
    context
    |> apply_project_setup()
    |> apply_technical_strategy()
    |> apply_code_generation()
    |> apply_qa_integration_plan()
    |> apply_architecture()
    |> apply_component_subgraph()
    |> apply_qa_artifacts()
    |> apply_persona()
    |> apply_story()
    |> apply_three_amigos_artifacts()
    |> apply_bdd_spec_file()
    |> apply_qa_story_artifacts()
    |> apply_journey_artifacts()
  end

  # 1. Project setup steps (project_setup requirement)
  # Setup.ApplicationInWeb writes `lib/my_app_web/application.ex` —
  # sync picks that up as a `MyAppWeb.Application` component, so we
  # must also write its canonical spec/impl/review companion files
  # to keep the post-sync graph fully green.
  defp apply_project_setup(context) do
    Fixtures.satisfy_setup_steps(context.environment, @all_setup_steps)

    # Setup.ApplicationInWeb writes the impl file → sync registers a
    # MyAppWeb.Application component (default_graph). Write its spec
    # and test files so the full chain (spec_file → spec_valid →
    # test_file → test_spec_alignment → implementation_file →
    # tests_passing) lands satisfied.
    write_companion_files(context.environment, "MyAppWeb.Application", "genserver")

    context
  end

  defp write_companion_files(env, module_name, type) do
    module_path = module_name |> String.split(".") |> Enum.map_join("/", &Macro.underscore/1)

    :ok =
      Environments.write_file(
        env,
        Content.spec_path(module_name),
        Content.child_spec(module_name, type: type, dependencies: [])
      )

    :ok =
      Environments.write_file(
        env,
        "test/#{module_path}_test.exs",
        """
        defmodule #{module_name}Test do
          use ExUnit.Case, async: true

          test "placeholder" do
            assert true
          end
        end
        """
      )

    :ok
  end

  # 2. Technical strategy ADRs index
  defp apply_technical_strategy(context) do
    Fixtures.with_decisions_index(context.environment)
    context
  end

  # 3. Code generation script
  defp apply_code_generation(context) do
    Fixtures.with_full_script(context.environment)
    context
  end

  # 4. QA integration plan
  defp apply_qa_integration_plan(context) do
    Fixtures.with_verified_integration_spec(context.environment, "stripe")
    context
  end

  # 5. Architecture proposal
  defp apply_architecture(context) do
    proposal_content =
      Fixtures.proposal_with_context(
        "MyApp",
        "Reservations",
        "Reservations bounded context for the fully-satisfied fixture."
      )

    Fixtures.with_proposal(context.environment, proposal_content)
    context
  end

  # 6. Component spec/impl topology
  # Single context component, no children → simplest viable subgraph.
  # Writes spec, impl, AND review files so review_file/review_valid
  # parent reqs are satisfied. With no children, child-scoped reqs
  # don't exist and parent's tests/test_file/etc. become vacuously
  # ready (no incoming child edges) — but those still need files
  # at the canonical paths.
  defp apply_component_subgraph(context) do
    env = context.environment
    module_name = "Reservations"
    module_path = module_name |> String.split(".") |> Enum.map_join("/", &Macro.underscore/1)

    :ok =
      Environments.write_file(
        env,
        Content.spec_path(module_name),
        Content.context_spec(module_name, type: "context", dependencies: [])
      )

    :ok =
      Environments.write_file(env, Content.impl_path(module_name), Content.impl_file(module_name))

    # Review file — design_review document type, valid sections.
    :ok =
      Environments.write_file(
        env,
        ".code_my_spec/spec/#{module_path}/design_review.md",
        design_review_content(module_name)
      )

    # Test file at canonical path for the parent context — file_exists check.
    :ok =
      Environments.write_file(
        env,
        "test/#{module_path}_test.exs",
        test_file_content(module_name)
      )

    {:ok, sync_live, _html} =
      live(context.conn, "/projects/#{context.project.name}/sync")

    sync_live |> element("button[phx-click='sync']") |> render_click()

    component = Fixtures.get_component_by_module_name(context.scope, module_name)
    Map.put(context, :component, component)
  end

  # 7. QA plan + preflight artifacts (qa_setup, qa_preflight)
  defp apply_qa_artifacts(context) do
    env = context.environment
    :ok = Environments.write_file(env, ".code_my_spec/qa/plan.md", qa_plan_content())
    :ok = Environments.write_file(env, ".code_my_spec/qa/preflight.md", qa_preflight_content())
    context
  end

  # 8. Persona via MCP + summary/sources files
  defp apply_persona(context) do
    frame = %Frame{assigns: %{current_scope: context.scope}}
    slug = "founder"

    {:reply, response, _frame} =
      CreatePersona.execute(
        %{slug: slug, name: "Founder", headline: "Solo founder shipping a product"},
        frame
      )

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

  # 9. Story linked to component, with criterion
  defp apply_story(context) do
    story =
      StoryHelpers.create_and_link(context.scope, context.component.module_name,
        title: "Reservations user story",
        description: "As a user, I want to manage reservations.",
        acceptance_criteria: ["User creates a reservation"],
        priority: 1
      )

    Map.put(context, :story, story)
  end

  # 10. Three Amigos artifacts: persona linked + rule + scenarios.
  # The Three Amigos readiness gate (BddRulesChecker) requires
  # kind-tagged scenarios — `acceptance_criteria` strings passed to
  # CreateStory produce criteria with kind=nil which DON'T count.
  # We add explicit kind-tagged scenarios via AddScenario MCP.
  defp apply_three_amigos_artifacts(context) do
    frame = %Frame{assigns: %{current_scope: context.scope}}

    {:reply, _response, _frame} =
      LinkPersonaToStory.execute(
        %{persona_id: context.persona_id, story_id: context.story.id},
        frame
      )

    rule_statement = "Reservations are owned by the user creating them"
    {:reply, _response, _frame} = add_rule_via_mcp(context.scope, context.story.id, rule_statement)

    {:reply, _response, _frame} =
      add_scenario_via_mcp(context.scope, context.story.id, rule_statement, "happy_path",
        title: "User creates a reservation they own",
        body:
          "Given the user is logged in\nWhen the user submits the reservation form\nThen a reservation is created with the user as owner"
      )

    {:reply, _response, _frame} =
      add_scenario_via_mcp(context.scope, context.story.id, rule_statement, "failure_path",
        title: "Anonymous visitor cannot create a reservation",
        body:
          "Given the visitor is not logged in\nWhen the visitor submits the reservation form\nThen the request is rejected with a redirect to login"
      )

    context
  end

  # 11. BDD spec file for the story → bdd_specs_exist + bdd_specs_passing
  defp apply_bdd_spec_file(context) do
    story = context.story
    [criterion | _] = story.criteria

    bdd_path = Fixtures.spec_file_path(story, criterion)

    :ok =
      Environments.write_file(
        context.environment,
        bdd_path,
        bdd_spec_content(story, criterion)
      )

    # Re-sync so the file is registered with role :bdd_spec
    {:ok, sync_live, _html} =
      live(context.conn, "/projects/#{context.project.name}/sync")

    sync_live |> element("button[phx-click='sync']") |> render_click()
    context
  end

  # 12. QA story brief + result → qa_complete
  defp apply_qa_story_artifacts(context) do
    env = context.environment
    story_id = context.story.id

    :ok =
      Environments.write_file(
        env,
        ".code_my_spec/qa/#{story_id}/brief.md",
        qa_brief_content()
      )

    :ok =
      Environments.write_file(
        env,
        ".code_my_spec/qa/#{story_id}/result.md",
        qa_result_content()
      )

    context
  end

  # 13. QA journey plan + result + wallaby → all three project journey reqs
  defp apply_journey_artifacts(context) do
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

  # -- Inline content helpers --

  defp design_review_content(module_name) do
    """
    # #{module_name} Design Review

    ## Overview

    Reviewed the #{module_name} context with no children. Sound
    architecture for a placeholder bounded context.

    ## Architecture

    - Separation of concerns is appropriate for a single-component
      context.
    - No child components present yet; the context exposes a public
      no-op function as a placeholder.

    ## Integration

    - The context has no integration points with other contexts.

    ## Conclusion

    Ready for implementation. No outstanding action items.
    """
  end

  defp test_file_content(module_name) do
    """
    defmodule #{module_name}Test do
      use ExUnit.Case, async: true

      test "placeholder" do
        assert true
      end
    end
    """
  end

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

  defp bdd_spec_content(story, criterion) do
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

    - Visit /reservations and verify the index page renders
    - Create a reservation via the form and verify success flash
    - Delete a reservation and verify it's removed from the list

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

    ### Index page renders

    Visited /reservations — page rendered with empty state placeholder.
    """
  end

  defp add_rule_via_mcp(scope, story_id, statement) do
    frame = %Frame{assigns: %{current_scope: scope}}

    CodeMySpec.McpServers.BddRules.Tools.AddRule.execute(
      %{story_id: story_id, statement: statement},
      frame
    )
  end

  defp add_scenario_via_mcp(scope, story_id, rule_statement, kind, opts) do
    frame = %Frame{assigns: %{current_scope: scope}}

    CodeMySpec.McpServers.BddRules.Tools.AddScenario.execute(
      %{
        story_id: story_id,
        rule_statement: rule_statement,
        kind: kind,
        title: Keyword.fetch!(opts, :title),
        body: Keyword.fetch!(opts, :body)
      },
      frame
    )
  end

  # AddCriterion is referenced for future use if extra criteria need to
  # be added — `create_story` already includes one acceptance criterion.
  _ = AddCriterion
end
