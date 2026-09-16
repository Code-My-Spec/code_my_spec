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

    test "consumes the marks it acted on", ctx do
      scope = ctx.scope
      create_story(scope, title: "A story", description: "one")

      project_live(scope)
      project_shadow(scope)

      GraphInputs.announce(scope, "Test", [])
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

    test "Stories names the story it changed", ctx do
      story = create_story(ctx.scope, title: "Named", description: "not project-wide")

      {named, project_wide?} = marks(ctx.scope)

      refute project_wide?, "Stories recorded a project-wide mark instead of naming the story"
      assert MapSet.member?(named, {"story", story.id})
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

      {named, project_wide?} = marks(ctx.scope)

      refute project_wide?, "Components recorded a project-wide mark"
      assert MapSet.member?(named, {"component", child.id})

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

      {named, project_wide?} = marks(ctx.scope)

      refute project_wide?, "AcceptanceCriteria recorded a project-wide mark"
      assert MapSet.member?(named, {"story", story.id})
    end
  end

  defp marks(scope) do
    scope.active_project_id |> Invalidations.pending() |> Invalidations.entities()
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

      alone = RequirementGraph.compute_entity(scope, ctx, config, {"component", component.id})

      # The claim `reduce_to/2` rests on: an entity hashes and answers
      # identically whether the pass that computed it was narrowed or whole. If
      # that ever stops holding, the shadow diff becomes a report on
      # `compute_entity/4` rather than on the staleness decision.
      assert Enum.all?(alone, &(&1.entity_id == component.id))

      again = RequirementGraph.compute_entity(scope, ctx, config, {"component", component.id})

      assert Enum.map(alone, &{&1.name, &1.satisfied}) ==
               Enum.map(again, &{&1.name, &1.satisfied})
    end
  end
end
