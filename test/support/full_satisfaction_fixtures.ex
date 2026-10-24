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
  - `qa_journey_plan`, `qa_journey_execute` — files written

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

  alias CodeMySpec.Environments
  alias CodeMySpecSpex.ComponentGraphHelpers
  alias CodeMySpecSpex.Fixtures
  alias CodeMySpecSpex.GraphContentFixtures, as: Content
  alias CodeMySpecSpex.ProjectStateFixtures
  alias CodeMySpecSpex.StoryHelpers

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
    |> apply_publication_record()
  end

  defp apply_publication_record(context) do
    {:ok, story} =
      Fixtures.record_story_publication(context.scope, context.story.id, "fixture-published")

    Map.put(context, :story, story)
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
    |> apply_up_to_analysis()
    |> apply_qa_readiness_transition()
  end

  @doc """
  The same chain, stopping short of everything that makes `qa_complete`
  actionable.

  Everything `apply_without_qa_story/1` does except the QA-readiness
  transition (`apply_qa_readiness_transition/1`), so a scenario can settle the
  whole project first and then make only that transition happen inside its
  `when_`.

  Criterion 3199 is why this is split out. It asserts that QA work reaches the
  QA agent and reaches no other, by comparing what each agent heard across the
  `when_` block. With the whole chain in there, a coding agent that has been
  running since the `given_` legitimately hears about its own work — the chain
  builds a project, and building a project is coding-role work — and a
  before/after comparison across the entire block cannot tell that from a role
  leak. The criterion failed on a correctly routed wake exactly as it would on
  a misrouted one.

  `apply_specs_enforced/1` used to be the last step here, on the theory that
  `apply_fresh_analysis_runs/1` alone was the transition that made
  `qa_complete` actionable. It is not: `SpecsPassingChecker.passing?/2` reads
  the `specs_ready` latch alone as satisfying `ready_for_qa` whenever no
  fresh spex run exists yet to contradict it, so enforcing specs before any
  spex run has happened satisfied the gate by itself, one step early. 3199
  found this by asserting the premise at the end of its first `given_` and
  watching it fail: `qa_complete` was already actionable here, before the
  `when_` it was meant to be exclusive to.
  """
  @spec apply_up_to_analysis(map()) :: map()
  def apply_up_to_analysis(context) do
    context
    |> apply_without_three_amigos()
    |> apply_three_amigos_artifacts()
    |> apply_bdd_spec_file()
    |> ProjectStateFixtures.apply_journey_artifacts()
  end

  @doc """
  Apply every satisfaction layer EXCEPT the story's `three_amigos_complete`
  artifacts -- the "story created, ready for design" state a scenario needs
  when it wants to claim and hold `three_amigos_complete` itself (e.g. to
  block that task on a question) rather than find it already satisfied.
  """
  @spec apply_without_three_amigos(map()) :: map()
  def apply_without_three_amigos(context) do
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
  end

  @doc """
  The QA-readiness transition: a fresh green analysis run, and the story
  certified ready for QA at a commit (`ready_for_qa`'s stamp), together.

  Split out of `apply_up_to_analysis/1` because the two steps cannot be
  separated and still leave `qa_complete` inactionable in between — see that
  function's doc for why. Public so a scenario's `when_` can trigger exactly
  this transition after settling everything else in its `given_`.
  """
  @spec apply_qa_readiness_transition(map()) :: map()
  def apply_qa_readiness_transition(context) do
    context
    |> apply_fresh_analysis_runs()
    |> apply_ready_for_qa()
  end

  # What completing `ready_for_qa` leaves behind: the story stamped with the
  # commit its copy was certified at. Directly, because certifying needs a
  # harness to read the tree and run the analyzers, which this frontier does
  # not have. Not `specs_ready` — that latch now means promoted, and a story on
  # its way to QA has not been. Reloaded, because `context.story` is the map
  # `StoryHelpers.fetch/2` answers rather than a `%Story{}`.
  defp apply_ready_for_qa(context) do
    story = CodeMySpec.Stories.get_story!(context.scope, context.story.id)
    {:ok, _} = CodeMySpec.Stories.set_qa_ready(context.scope, story, String.duplicate("a", 40))
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

  # 6. Component topology
  # Single context component, designed, with its code → simplest viable
  # subgraph. With no children, child-scoped reqs don't exist.
  defp apply_component_subgraph(context) do
    env = context.environment
    module_name = "Reservations"
    module_path = module_name |> String.split(".") |> Enum.map_join("/", &Macro.underscore/1)

    ComponentGraphHelpers.design!(context, module_name)

    :ok =
      Environments.write_file(env, Content.impl_path(module_name), Content.impl_file(module_name))

    # Test file at canonical path for the parent context — file_exists check.
    :ok =
      Environments.write_file(
        env,
        "test/#{module_path}_test.exs",
        test_file_content(module_name)
      )

    # The sync itself, not the button that calls it.
    #
    # `FilesLive`'s handler is `FileSync.sync/2` then
    # `ComponentSync.sync_from_files/2`, so driving it through the LiveView adds
    # a test process and nothing else — and `live/2` raises "LiveView helpers
    # can only be invoked from the test process", which made this fixture
    # unusable from `mix cms.eval`. Setup is not the surface under test.
    ProjectStateFixtures.synced(context)

    component = Fixtures.get_component_by_module_name(context.scope, module_name)
    Map.put(context, :component, component)
  end

  @doc """
  Two children of the story's component, designed and not yet written: two
  pieces of coding work open at once on the active story, where everything
  else here leaves one. Records only, so it runs beside a live harness.
  """
  @spec apply_two_components_to_implement(map()) :: map()
  def apply_two_components_to_implement(context) do
    parent = context.component.module_name

    for child <- ["Booking", "Slot"],
        do:
          ComponentGraphHelpers.design!(context, "#{parent}.#{child}", [],
            parent: parent,
            type: "schema"
          )

    :ok = Fixtures.settle_graph(context.scope)
    context
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

  @doc """
  Three Amigos artifacts: persona linked + rule + scenarios, satisfying
  `three_amigos_complete` without touching anything downstream of it
  (`bdd_specs_exist` stays actionable). Public so a scenario can claim and
  hold that requirement itself, the way `apply_without_three_amigos/1` does
  one stage earlier for `three_amigos_complete`.
  """
  @spec apply_three_amigos_artifacts(map()) :: map()
  def apply_three_amigos_artifacts(context) do
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
