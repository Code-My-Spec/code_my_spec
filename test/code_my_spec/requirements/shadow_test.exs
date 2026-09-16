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
