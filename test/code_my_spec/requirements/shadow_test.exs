defmodule CodeMySpec.Requirements.ShadowTest do
  @moduledoc """
  The event-based projection against the one it is replacing.

  The diff *is* the test. Every assertion here is a statement about the two
  projections agreeing — not about the mechanism that got them there — because
  agreement is the whole claim and any test of the mechanism would pass just as
  happily on a shadow that is confidently wrong.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.StoryHelpers, only: [create_story: 2]

  alias CodeMySpec.ComponentsFixtures
  alias CodeMySpec.Requirements.GraphInputs
  alias CodeMySpec.Requirements.Invalidations
  alias CodeMySpec.Requirements.Preloader
  alias CodeMySpec.Requirements.RequirementGraph
  alias CodeMySpec.Requirements.Shadow
  alias CodeMySpec.Requirements.ShadowProjector

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    Application.put_env(:code_my_spec, :graph_shadow_projection, true)
    on_exit(fn -> Application.delete_env(:code_my_spec, :graph_shadow_projection) end)

    :ok
  end

  # The live projection has to exist before anything can be compared to it.
  defp project_live(scope) do
    RequirementGraph.recompute(scope)
    :ok
  end

  defp project_shadow(scope) do
    {:ok, pid} = ShadowProjector.ensure_projecting(scope)
    :ok = ShadowProjector.settle(scope.active_project_id)
    pid
  end

  describe "a seeded shadow" do
    test "agrees with the live projection on a project it has never seen", ctx do
      scope = ctx.scope
      ComponentsFixtures.component_fixture(scope)
      create_story(scope, title: "A story", description: "one")

      project_live(scope)
      project_shadow(scope)

      report = Shadow.diff(scope)

      assert report.live > 0, "the live projection wrote nothing, so there is nothing to compare"
      assert report.missing == 0, "shadow is missing rows: #{inspect(report.sample)}"
      assert report.disagree == 0, "shadow disagrees: #{inspect(report.sample)}"
    end
  end

  describe "a maintained shadow" do
    test "picks up an entity that appeared after it was seeded", ctx do
      scope = ctx.scope
      create_story(scope, title: "A story", description: "one")

      project_live(scope)
      project_shadow(scope)

      # An entity the shadow's seed could not have seen, created through the
      # real surface rather than by poking the projector. This is the
      # assertion the rename it replaced could not make: a rename moves a
      # story's fingerprint without moving any verdict, so the diff read zero
      # whether or not the event path did anything at all.
      #
      # A new story has requirements that did not exist, so every one of them is
      # `missing` unless `Stories` recorded a mark and the projector acted on
      # it. The test fails if any link in that chain is absent.
      create_story(scope, title: "A second story", description: "two")

      project_live(scope)
      :ok = ShadowProjector.settle(scope.active_project_id)

      report = Shadow.diff(scope)

      assert report.missing == 0, "shadow is missing rows: #{inspect(report.sample)}"
      assert report.disagree == 0, "shadow disagrees: #{inspect(report.sample)}"
    end

    test "a handled event still settles every requirement it can move", ctx do
      scope = ctx.scope
      story = create_story(scope, title: "To be sealed", description: "three amigos")

      project_live(scope)
      project_shadow(scope)

      # Sealing moves `three_amigos_complete`. It goes through
      # `Stories.update_story/3`, so if that emits an event the projector
      # handles, the fallback marks are dropped by observation id — and any
      # requirement the handler does *not* settle is left at its old verdict
      # with nothing to correct it.
      #
      # This is the general rule the creation case was one instance of: an
      # event kind may only be handled when its handlers settle everything that
      # event can move.
      {:ok, _} =
        CodeMySpec.Stories.update_story(
          scope,
          CodeMySpec.Stories.get_story!(scope, story.id),
          %{three_amigos_sealed: true}
        )

      project_live(scope)
      :ok = ShadowProjector.settle(scope.active_project_id)

      report = Shadow.diff(scope)

      assert report.disagree == 0,
             "a handled story event left a requirement stale: #{inspect(report.sample)}"

      assert report.missing == 0, "shadow is missing rows: #{inspect(report.sample)}"
    end

    test "consumes the marks it acted on", ctx do
      scope = ctx.scope
      create_story(scope, title: "A story", description: "one")

      project_live(scope)
      project_shadow(scope)

      GraphInputs.announce(scope, "Test", [], :project_wide)
      assert Invalidations.pending(scope.active_project_id) != []

      :ok = ShadowProjector.settle(scope.active_project_id)

      assert Invalidations.pending(scope.active_project_id) == [],
             "a mark the projector acted on must not be handled twice"
    end
  end

  describe "writer coverage" do
    # One case per writer that announces, each going through the real surface
    # rather than poking the projector, because what is being tested is whether
    # that writer's announcement reaches the event path at all.
    #
    # This is the matrix that decides the remaining work. A writer that fails
    # here is silent — no mark, so no recompute, so a row nothing revisits —
    # and that is the only failure the diff can actually see. A writer that
    # passes may still be recording project-wide and dragging the whole project
    # through a recompute; that costs, it does not lie, and it is priced
    # separately.
    setup ctx do
      story = create_story(ctx.scope, title: "Subject", description: "under test")
      component = ComponentsFixtures.component_fixture(ctx.scope)

      project_live(ctx.scope)
      project_shadow(ctx.scope)

      {:ok, story: story, component: component}
    end

    test "Issues reaches the event path", ctx do
      {:ok, _} =
        CodeMySpec.Issues.create_issue(ctx.scope, %{
          title: "something is wrong",
          description: "filed during the shadow diff",
          severity: :medium
        })

      assert_shadow_agrees(ctx.scope, "Issues")
    end

    test "AcceptanceCriteria reaches the event path", ctx do
      {:ok, _} =
        CodeMySpec.AcceptanceCriteria.create_criterion(
          ctx.scope,
          CodeMySpec.Stories.get_story!(ctx.scope, ctx.story.id),
          %{description: "a criterion that moves the graph"}
        )

      assert_shadow_agrees(ctx.scope, "AcceptanceCriteria")
    end

    test "Questions reaches the event path", ctx do
      {:ok, _} =
        CodeMySpec.Questions.create_question(ctx.scope, ctx.story.id, %{
          text: "does this reach the event path?"
        })

      assert_shadow_agrees(ctx.scope, "Questions")
    end

    test "Components reaches the event path", ctx do
      {:ok, _} =
        CodeMySpec.Components.create_component(ctx.scope, %{
          name: "Appeared",
          type: "context",
          module_name: "Appeared",
          description: "a component created after the shadow was seeded"
        })

      assert_shadow_agrees(ctx.scope, "Components")
    end

    test "Stories reaches the event path", ctx do
      create_story(ctx.scope, title: "Appeared", description: "after seeding")

      assert_shadow_agrees(ctx.scope, "Stories")
    end

    test "accepting an issue on a story moves that story's verdict", ctx do
      {:ok, issue} =
        CodeMySpec.Issues.create_issue(ctx.scope, %{
          title: "breaks the story",
          description: "attributed, and about to be accepted",
          severity: :high,
          story_id: ctx.story.id
        })

      # The case the other coverage tests cannot make. Creating an issue does
      # not move any story verdict — `IssuesChecker.story_resolved?/2` counts
      # only issues that are *accepted* at or above the severity threshold — so
      # a writer naming nothing but `:project` would still agree.
      #
      # Accepting one flips `story_issues_resolved` from true to false for that
      # story alone. If `Issues` named only the project, the shadow would keep
      # the old verdict and this reads as `disagree`.
      {:ok, _} = CodeMySpec.Issues.accept_issue(ctx.scope, issue)

      assert_shadow_agrees(ctx.scope, "Issues (accepted)")
    end
  end

  describe "writer narrowing" do
    # The coverage matrix above cannot tell a narrowed writer from an
    # un-narrowed one: both agree, because a project-wide mark recomputes every
    # entity and therefore never disagrees. Narrowing is the *cost* half, and
    # this is where it is actually asserted — on the shape of the mark rather
    # than on the projection that follows from it.
    #
    # Only the writers that have been narrowed are here. The rest record
    # project-wide today and are expected to; when one is narrowed it earns a
    # case, and that is the checklist for the work remaining.
    setup ctx do
      create_story(ctx.scope, title: "Subject", description: "under test")
      project_live(ctx.scope)
      Invalidations.consume(Invalidations.pending(ctx.scope.active_project_id))
      :ok
    end

    # Story 1020, "A writer says whether what it moved is about one checkout or
    # about the whole project". The narrowing above is about *which entities*;
    # this is about *whose answers*, and the two are independent — a writer can
    # name one story precisely and still be wrong about which checkouts read it.
    #
    # Asserted on the mark rather than on the projection for the same reason the
    # rest of this block is: a mark that fans out when it should not still
    # agrees, because settling every vantage is never *wrong*, only wasteful.
    # Only the shape says which happened.
    test "a story change is about no checkout in particular", ctx do
      create_story(ctx.scope, title: "Everyone's", description: "read from every checkout")

      assert copies_named(ctx.scope, "Stories") == [nil],
             """
             A story is not a checkout's. Taking the copy from the writer's ambient
             scope would settle the worktree the rename happened in and leave every
             other checkout carrying the old title.
             """
    end

    test "an analyzer result is about the checkout it ran on", ctx do
      scope = ctx.scope

      # Or the assertion below is `[nil] == [nil]` and says nothing. The whole
      # point is that a `:this_checkout` writer records something a
      # `:project_wide` writer does not.
      refute is_nil(scope.active_working_copy_id),
             "this test needs a scope with a checkout on it, or it passes vacuously"

      GraphInputs.event(
        scope,
        "Analysis",
        "analysis_completed",
        %{},
        [:project],
        :this_checkout
      )

      assert copies_named(scope, "Analysis") == [scope.active_working_copy_id]
    end

    test "a writer that cannot say is read as the whole project", ctx do
      scope = ctx.scope

      # `:this_checkout` from a scope with no checkout on it is not a narrowing
      # that failed, it is a writer speaking from nowhere — and that has to read
      # as every checkout, never as the `nil` *vantage*, which is one particular
      # row-space a reader with no checkout is answered from.
      GraphInputs.event(
        %{scope | active_working_copy_id: nil},
        "Nowhere",
        "analysis_completed",
        %{},
        [:project],
        :this_checkout
      )

      assert copies_named(scope, "Nowhere") == [nil]
    end

    test "Stories names the story it changed, and claims project scope", ctx do
      story = create_story(ctx.scope, title: "Named", description: "not project-wide")

      {named, flags} = marks(ctx.scope)

      refute flags[:unknown?], "Stories could not say what it moved"
      assert MapSet.member?(named, {"story", story.id})

      # Three project requirements read stories — `stories_exist`,
      # `work_dispatched` and the unlinked-story half of `architecture_designed`
      # — so this writer has to say so. Naming only the story would be asserting
      # a blast radius it does not have, and the project node would go stale
      # with nothing to say so.
      assert flags[:project?], "a story moving must invalidate the project requirements"
    end

    test "Components names the component and its parent", ctx do
      parent = ComponentsFixtures.component_fixture(ctx.scope)
      Invalidations.consume(Invalidations.pending(ctx.scope.active_project_id))

      {:ok, child} =
        CodeMySpec.Components.create_component(ctx.scope, %{
          name: "Child",
          type: "context",
          module_name: "Child",
          description: "a child of the fixture",
          parent_component_id: parent.id
        })

      {named, flags} = marks(ctx.scope)

      refute flags[:unknown?], "Components could not say what it moved"
      assert MapSet.member?(named, {"component", child.id})

      # `architecture_designed` reads the component set.
      assert flags[:project?], "a component moving must invalidate the project requirements"

      # `Freshness.component/2` hashes `children_by_parent`, so a child
      # appearing moves the parent's requirements too. A writer that named only
      # the child would leave the parent stale with nothing to say so.
      assert MapSet.member?(named, {"component", parent.id}),
             "a child appearing must invalidate its parent"
    end

    test "AcceptanceCriteria names the story its criterion hangs off", ctx do
      story = create_story(ctx.scope, title: "Owner", description: "of a criterion")
      Invalidations.consume(Invalidations.pending(ctx.scope.active_project_id))

      {:ok, _} =
        CodeMySpec.AcceptanceCriteria.create_criterion(
          ctx.scope,
          CodeMySpec.Stories.get_story!(ctx.scope, story.id),
          %{description: "a criterion that moves one story"}
        )

      # Filtered to this writer's own marks, because `create_criterion/3` is not
      # only a criterion write: it calls `restart_specs_chain/3`, which resets
      # the story's specs-ready latch through `Stories`, which correctly claims
      # project scope. That `:project` mark is real and belongs to `Stories`.
      #
      # The claim under test is about this writer: no project requirement reads
      # acceptance criteria, so `AcceptanceCriteria` must not itself drag the
      # project nodes through a recompute — 60-95ms on the live project, for a
      # verdict that cannot have moved.
      {named, flags} = marks_from(ctx.scope, "AcceptanceCriteria")

      refute flags[:unknown?], "AcceptanceCriteria could not say what it moved"
      assert MapSet.member?(named, {"story", story.id})

      refute flags[:project?],
             "no project requirement reads criteria, so this must not claim project scope"
    end
  end

  test "Issues names the story it was attributed to, and the project", ctx do
    story = create_story(ctx.scope, title: "Blamed", description: "for an issue")
    Invalidations.consume(Invalidations.pending(ctx.scope.active_project_id))

    {:ok, issue} =
      CodeMySpec.Issues.create_issue(ctx.scope, %{
        title: "attributed",
        description: "to a story",
        severity: :medium,
        story_id: story.id
      })

    {named, flags} = marks_from(ctx.scope, "Issues")

    refute flags[:unknown?], "Issues could not say what it moved"
    assert MapSet.member?(named, {"story", issue.story_id})

    # `issues_triaged` and `issues_resolved` are project requirements reading
    # the whole queue, so every issue moves them.
    assert flags[:project?], "an issue must invalidate the project issue queue"
  end

  test "Issues with no story names only the project", ctx do
    Invalidations.consume(Invalidations.pending(ctx.scope.active_project_id))

    {:ok, _} =
      CodeMySpec.Issues.create_issue(ctx.scope, %{
        title: "unattributed",
        description: "belongs to the queue, not a story",
        severity: :low
      })

    {named, flags} = marks_from(ctx.scope, "Issues")

    # `IssuesChecker.story_resolved?/2` draws this line itself: an issue with
    # no `story_id` is the project queue's problem, not any story's. Naming a
    # story here would recompute it for nothing.
    assert MapSet.size(named) == 0, "an unattributed issue must name no story"
    assert flags[:project?]
    refute flags[:unknown?]
  end

  defp marks(scope) do
    scope.active_project_id |> Invalidations.pending() |> Invalidations.entities()
  end

  defp marks_from(scope, source) do
    scope.active_project_id
    |> Invalidations.pending()
    |> Enum.filter(&(&1.source == source))
    |> Invalidations.entities()
  end

  # The checkouts a writer's marks name, `nil` included — `nil` is an answer
  # ("not about a checkout"), not a missing one, so it is never filtered out.
  defp copies_named(scope, source) do
    scope.active_project_id
    |> Invalidations.pending()
    |> Enum.filter(&(&1.source == source))
    |> Enum.map(& &1.working_copy_id)
    |> Enum.uniq()
  end

  defp assert_shadow_agrees(scope, writer) do
    project_live(scope)
    :ok = ShadowProjector.settle(scope.active_project_id)

    report = Shadow.diff(scope)

    assert report.missing == 0,
           "#{writer} left the shadow missing rows: #{inspect(report.sample)}"

    assert report.disagree == 0,
           "#{writer} left the shadow disagreeing: #{inspect(report.sample)}"
  end

  describe "computing one entity" do
    test "answers the same as computing it inside a whole pass", ctx do
      scope = ctx.scope
      component = ComponentsFixtures.component_fixture(scope)

      {:ok, ctx} = Preloader.load(scope)
      config = CodeMySpec.Configurations.get_or_create(scope)

      {_, alone} =
        RequirementGraph.compute_entity(scope, ctx, config, {"component", component.id})

      # The claim `reduce_to/2` rests on: an entity hashes and answers
      # identically whether the pass that computed it was narrowed or whole. If
      # that ever stops holding, the shadow diff becomes a report on
      # `compute_entity/4` rather than on the staleness decision.
      assert Enum.all?(alone, &(&1.entity_id == component.id))

      {_, again} =
        RequirementGraph.compute_entity(scope, ctx, config, {"component", component.id})

      assert Enum.map(alone, &{&1.name, &1.satisfied}) ==
               Enum.map(again, &{&1.name, &1.satisfied})
    end

    test "a narrow story load answers the same as the whole context", ctx do
      scope = ctx.scope
      story = create_story(scope, title: "Narrowly loaded", description: "one story")

      {:ok, full} = Preloader.load(scope)
      config = CodeMySpec.Configurations.get_or_create(scope)

      {:ok, narrow} = Preloader.load_story(scope, story.id, full.analysis_fresh)

      {_, from_full} =
        RequirementGraph.compute_entity(scope, full, config, {"story", story.id})

      {_, from_narrow} =
        RequirementGraph.compute_entity(scope, narrow, config, {"story", story.id})

      # The whole claim of `load_story/3`: the story graph's delegates query per
      # story anyway, so a context holding only that story answers every one of
      # its eight requirements identically. If this ever stops holding, the
      # narrow path is silently deciding from less than the checkers need.
      assert Enum.map(from_full, &{&1.name, &1.satisfied}) ==
               Enum.map(from_narrow, &{&1.name, &1.satisfied}),
             "narrow and whole-context loads disagree about this story's requirements"

      assert from_narrow != [], "the narrow load produced no requirements at all"

      # And it stamps no fingerprint, deliberately. A hash over a narrow context
      # is not the hash a whole pass produces, so a plausible-looking one would
      # be worse than none — `nil` already means "no basis to skip this row".
      assert Enum.all?(from_narrow, &is_nil(&1.inputs_fingerprint)),
             "the narrow path must not stamp a fingerprint it cannot compute correctly"

      assert Enum.all?(from_full, &is_binary(&1.inputs_fingerprint)),
             "the whole-context path must still stamp one"
    end

    test "a story outside this vantage's scope loads as empty", ctx do
      scope = ctx.scope
      story = create_story(scope, title: "Parked", description: "not ready")

      {:ok, _} =
        CodeMySpec.Stories.update_story(
          scope,
          CodeMySpec.Stories.get_story!(scope, story.id),
          %{ready_for_dev: false}
        )

      {:ok, narrow} = Preloader.load_story(scope, story.id, %{})

      # `load/1` gates on `ready_for_dev` and on the assignment rule, and the
      # narrow load has to apply the same filter or it would compute rows for a
      # story the live projection deliberately holds none for.
      assert narrow.stories == [],
             "a parked story must not load, or the event path computes rows the pass would not"
    end

    test "a nested component answers the same alone as inside its family", ctx do
      scope = ctx.scope
      parent = ComponentsFixtures.component_fixture(scope, %{type: "context"})

      {:ok, child} =
        CodeMySpec.Components.create_component(scope, %{
          name: "NestedChild",
          type: "genserver",
          module_name: "NestedChild",
          description: "a child of a context",
          parent_component_id: parent.id
        })

      {:ok, loaded} = Preloader.load(scope)
      config = CodeMySpec.Configurations.get_or_create(scope)

      {covered, from_child} =
        RequirementGraph.compute_entity(scope, loaded, config, {"component", child.id})

      {_, from_parent} =
        RequirementGraph.compute_entity(scope, loaded, config, {"component", parent.id})

      # `component_families/1` classifies top-level from nested by asking whether
      # each component's parent is in the set it was handed. Narrowed to the
      # child alone, the parent is absent, the child reads as top-level and runs
      # its own template — inventing rows the whole-project pass never produces.
      # Measured on the live project before this was fixed: 549 of 1138
      # components nested, every one of them gaining a spurious
      # `implementation_file`.
      #
      # So a component's unit of computation is its family, and asking about
      # either member must answer identically.
      assert MapSet.member?(covered, {"component", parent.id}),
             "computing a child must cover its parent, or the child is misclassified as top-level"

      assert names_for(from_child, child.id) == names_for(from_parent, child.id)
      assert names_for(from_child, parent.id) == names_for(from_parent, parent.id)
    end
  end

  defp names_for(nodes, entity_id) do
    nodes |> Enum.filter(&(&1.entity_id == entity_id)) |> Enum.map(& &1.name) |> Enum.sort()
  end
end
