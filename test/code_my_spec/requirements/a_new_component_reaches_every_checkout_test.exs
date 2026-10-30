defmodule CodeMySpec.Requirements.ANewComponentReachesEveryCheckoutTest do
  @moduledoc """
  A component appearing gives every checkout rows for it, not just the one that
  made it.

  The `components` table has no `working_copy_id`: a component belongs to the
  project, and every checkout projects requirements for every component. What
  differs per checkout is the *answers* — its files are read per checkout — not
  whether the requirements exist.

  So the two halves of a component event are not the same observation. A change
  moves one checkout's answers. An appearance or a disappearance changes the
  entity set for all of them.

  ## What went wrong

  `Components` announced every kind as `:this_checkout`. Handlers settle rows
  and never create them, so a new component's rows can only come from the
  fallback — and the fallback runs only where the mark points. Every checkout
  except the creator was left without rows for it.

  Measured on dev, 2026-09-17: ten components created in five minutes, and the
  diff sat at `missing 4-6, extra 0` on every vantage and did not converge.
  `extra 0` is the tell — the projection was behind on creation rather than
  wrong about anything it held.
  """
  use CodeMySpecSpex.Case, async: true

  alias CodeMySpec.Requirements.{IncrementalGraph, RequirementGraph}
  alias CodeMySpecSpex.Fixtures

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    :ok
  end

  defp settle(scope) do
    {:ok, _pid} = IncrementalGraph.ensure_projecting(scope)
    :ok = IncrementalGraph.settle(scope.active_project_id)
  end

  # The component's nodes in the graph served at this checkout.
  defp nodes_at(scope, component_id) do
    {nodes, _edges} = RequirementGraph.served_graph(scope, RequirementGraph.read_context(scope))
    Enum.count(nodes, &(&1.entity_id == component_id))
  end

  describe "a component created in one checkout" do
    test "has requirements at every checkout", ctx do
      first = ctx.scope
      second = Fixtures.live_agent_scope(first, label: "the other checkout")

      # Both vantages have to be projected before either can be missing
      # anything: a checkout nobody has computed for holds no rows at all, and
      # absence there means "never computed" rather than "wrong".
      CodeMySpec.ComponentsFixtures.component_fixture(first)
      CodeMySpec.Requirements.recompute(first)
      CodeMySpec.Requirements.recompute(second)
      settle(first)

      # Now the observation under test: a component appears.
      {:ok, arrived} =
        CodeMySpec.Components.create_component(first, %{
          name: "Arrived",
          type: "context",
          module_name: "Arrived",
          description: "created in one checkout, real in all of them"
        })

      settle(first)

      assert nodes_at(first, arrived.id) > 0,
             "the checkout that created it has no requirements for it"

      assert nodes_at(second, arrived.id) > 0,
             """
             A component was created and this checkout has no requirements for
             it at all.

             A component belongs to the project — `components` has no
             `working_copy_id` — so every checkout projects requirements for it.
             Narrowing the creation to the checkout that made it leaves the rest
             with nothing, and handlers cannot repair that: they settle rows and
             never create them, so only the fallback creates them and it runs
             only where the mark points.
             """
    end
  end
end
