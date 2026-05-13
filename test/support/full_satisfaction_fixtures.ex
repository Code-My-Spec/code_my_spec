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
    |> ProjectStateFixtures.apply_project_setup_steps()
    |> ProjectStateFixtures.apply_technical_strategy()
    |> ProjectStateFixtures.apply_code_generation()
    |> ProjectStateFixtures.apply_qa_integration_plan()
    |> ProjectStateFixtures.apply_architecture()
    |> ProjectStateFixtures.apply_spex_boundary_ready()
    |> apply_component_subgraph()
    |> ProjectStateFixtures.apply_qa_setup_preflight()
    |> ProjectStateFixtures.apply_persona()
    |> apply_story()
    |> apply_three_amigos_artifacts()
    |> apply_bdd_spec_file()
    |> apply_qa_story_artifacts()
    |> ProjectStateFixtures.apply_journey_artifacts()
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
      live(context.conn, "/projects/#{context.project.name}/files")

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

  # 11. BDD spec file for the story → bdd_specs_exist + bdd_specs_passing
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
