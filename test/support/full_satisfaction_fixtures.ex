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
  - `stories_exist` — DB story via `StoryHelpers.create_and_link/3`
  - `code_generation` — via `Fixtures.with_full_script/1`
  - `qa_integration_plan` — via `Fixtures.with_verified_integration_spec/2`
  - `architecture_designed` — via `Fixtures.with_proposal/2`
  - `issues_triaged`, `issues_resolved` — vacuous (no incoming issues)
  - `qa_setup` — write `.code_my_spec/qa/plan.md`
  - `qa_journey_plan`, `qa_journey_execute`, `qa_journey_wallaby` — files written

  Story-level requirements:
  - `component_linked` — `set_story_component` MCP
  - `three_amigos_complete` — persona linked + rule + criterion (via MCP)
  - `bdd_specs_exist` — bdd spec file written
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

  alias CodeMySpec.Environments
  alias CodeMySpec.McpServers.Stories.Tools.AddCriterion
  alias CodeMySpecSpex.Fixtures
  alias CodeMySpecSpex.GraphContentFixtures, as: Content
  alias CodeMySpecSpex.ProjectStateFixtures
  alias CodeMySpecSpex.StoryHelpers

  @endpoint CodeMySpecLocalWeb.Endpoint

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
    # Project-level kickoff (extracted into ProjectStateFixtures for reuse).
    # `apply_persona` is folded into kickoff there; the result still merges
    # `:persona_slug` and `:persona_id` into context for the story-level
    # steps below.
    |> apply_without_release()
    |> ProjectStateFixtures.apply_release_record()
  end

  @doc """
  Apply every satisfaction layer EXCEPT the prod release record — the
  "deployed to UAT, release pending" state the release spex (story 859)
  start from. The story's deploy record exists but no release manifest
  covers it, so the `release` requirement reads unsatisfied.
  """
  @spec apply_without_release(map()) :: map()
  def apply_without_release(context) do
    context
    |> apply_without_deploy()
    |> ProjectStateFixtures.apply_deploy_record()
  end

  @doc """
  Apply every satisfaction layer EXCEPT the story's `deploy` record —
  the "story just cleared QA, promotion pending" state the loop-deploy
  spex (story 858) start from.
  """
  @spec apply_without_deploy(map()) :: map()
  def apply_without_deploy(context) do
    context
    |> apply_without_qa_story()
    |> apply_qa_story_artifacts()
  end

  @doc """
  Apply every satisfaction layer EXCEPT the story-level `qa_complete`
  artifacts. Useful when a spex needs the chain prepared so a
  `qa_complete` task can be STARTED (i.e. its prerequisites are met
  but the requirement itself is open).
  """
  @spec apply_without_qa_story(map()) :: map()
  def apply_without_qa_story(context) do
    context
    |> ProjectStateFixtures.apply_project_setup_steps()
    |> ProjectStateFixtures.apply_technical_strategy()
    |> ProjectStateFixtures.apply_code_generation()
    |> ProjectStateFixtures.apply_qa_integration_plan()
    |> ProjectStateFixtures.apply_devops_setup()
    |> ProjectStateFixtures.apply_architecture()
    |> ProjectStateFixtures.apply_spex_boundary_ready()
    |> apply_component_subgraph()
    |> ProjectStateFixtures.apply_qa_setup()
    |> ProjectStateFixtures.apply_persona()
    |> apply_story()
    |> apply_three_amigos_artifacts()
    |> apply_bdd_spec_file()
    |> apply_specs_enforced()
    |> ProjectStateFixtures.apply_journey_artifacts()
    |> apply_fresh_analysis_runs()
  end

  # `bdd_specs_passing` checks the story's `specs_ready` latch, and writing the
  # spec file satisfies `bdd_specs_exist` and nothing more. Without this the
  # chain stopped one requirement short of where its own docstring says it
  # stops: `qa_complete` never became reachable, so every spex built on this
  # frontier got a `FixBddSpecs` prompt for the story the fixture had just
  # created, naming an id that changed on every run.
  #
  # Through the button rather than `Stories.set_specs_ready/3`, for two
  # reasons: this module's rule is bridge fixtures and MCP tools only, and the
  # latch has no MCP surface at all — deliberately, since it decides whether
  # spex failures block the agent, which is not the agent's call to make. The
  # toggle in StoryLive is the whole of how it gets set.
  defp apply_specs_enforced(context) do
    {:ok, view, _html} =
      live(context.conn, "/app/projects/#{context.project.id}/stories")

    view
    |> element(~s{[data-test="toggle-story-specs-ready"][phx-value-id="#{context.story.id}"]})
    |> render_click()

    context
  end

  # tests_passing / spex_passing require a fresh completed analysis run at
  # the current input fingerprint (v1.5.36 run ledger) — "zero problems
  # because the suites never ran" is no longer satisfiable. Stamp AFTER the
  # last code/spec file lands; the qa-role artifacts written later don't
  # feed any analyzer's fingerprint.
  defp apply_fresh_analysis_runs(context) do
    Fixtures.fresh_analysis_runs(context.scope)
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
      live(context.conn, "/app/projects/#{context.project.id}/files")

    sync_live |> element("button[phx-click='sync']") |> render_click()

    component = Fixtures.get_component_by_module_name(context.scope, module_name)
    Map.put(context, :component, component)
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
  defp apply_three_amigos_artifacts(context) do
    :ok =
      ProjectStateFixtures.apply_three_amigos_for_story(context.scope, context.story,
        persona_id: context.persona_id,
        rule_statement: "Reservations are owned by the user creating them",
        happy_title: "User creates a reservation they own",
        happy_body:
          "Given the user is logged in\nWhen the user submits the reservation form\nThen a reservation is created with the user as owner",
        failure_title: "Anonymous visitor cannot create a reservation",
        failure_body:
          "Given the visitor is not logged in\nWhen the visitor submits the reservation form\nThen the request is rejected with a redirect to login"
      )

    context
  end

  # 11. BDD spec file for the story → bdd_specs_exist
  defp apply_bdd_spec_file(context) do
    :ok = ProjectStateFixtures.apply_bdd_spec_for_story(context, context.story)
    context
  end

  # 12. QA story brief + result → qa_complete
  defp apply_qa_story_artifacts(context) do
    :ok = ProjectStateFixtures.apply_qa_complete_for_story(context, context.story)
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

  # AddCriterion is referenced for future use if extra criteria need to
  # be added — `create_story` already includes one acceptance criterion.
  _ = AddCriterion
end
