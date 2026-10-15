defmodule CodeMySpec.Requirements.ADependencyDeclaredRedrawsTheEdgesTest do
  @moduledoc """
  A dependency declared or withdrawn moves the edges, and only the edges.

  Nothing announced it. `DependencyRepository` was a plain insert and delete,
  so a dependency added by hand or by a scan of a spec's `## Dependencies`
  moved no mark, and the projector — which redraws edges only when a drain
  tells it the shape moved — went on serving the kickoff and cross-context
  edges of the shape before it, until something unrelated happened to move
  the shape.

  What a dependency changes: the cross-context edge from the target's last
  requirement to the source's first, and every story kicked off through the
  source, whose fan-out now lands on the target instead. What it does not
  change: any verdict. So the kind is handled as moving nothing and listed as
  a shape kind, and the drain redraws.
  """
  use CodeMySpecSpex.Case, async: true

  alias CodeMySpec.Components
  alias CodeMySpec.Requirements.Edge
  alias CodeMySpec.Requirements.GraphStore
  alias CodeMySpec.Requirements.IncrementalGraph
  alias CodeMySpec.Requirements.Preloader
  alias CodeMySpec.Requirements.Projection
  alias CodeMySpec.Stories

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    :ok
  end

  describe "a story kicked off through a context" do
    test "is redrawn through the dependency the context declares, and back", %{scope: scope} do
      accounts = component(scope, "Accounts")
      billing = component(scope, "Billing")

      {:ok, story} =
        Stories.create_story(scope, %{
          ready_for_dev: true,
          title: "Invoice a customer",
          description: "As a clerk, I invoice a customer",
          acceptance_criteria: ["An invoice exists"],
          component_id: billing.id
        })

      settle(scope)
      before = edges(scope)

      assert kicks_off?(before, story.id, billing.id), "the story is not drawn at all"
      refute kicks_off?(before, story.id, accounts.id)
      refute joins?(before, accounts.id, billing.id)

      {:ok, dependency} =
        Components.create_dependency(scope, %{
          source_component_id: billing.id,
          target_component_id: accounts.id
        })

      settle(scope)
      declared = edges(scope)

      assert joins?(declared, accounts.id, billing.id),
             """
             Billing now depends on Accounts and no edge joins them.

             The dependency was inserted and nothing told the projector the
             shape moved, so the edges are the ones drawn before it.
             """

      assert kicks_off?(declared, story.id, accounts.id),
             "the story's kickoff should land on the head of the chain it now has"

      refute kicks_off?(declared, story.id, billing.id),
             "a kickoff straight to Billing is redundant once Accounts gates it"

      {:ok, _deleted} = Components.delete_dependency(scope, dependency)
      settle(scope)
      withdrawn = edges(scope)

      assert withdrawn == before,
             """
             Withdrawing the dependency should leave the edges as they were.

             extra:   #{inspect(MapSet.difference(withdrawn, before) |> Enum.take(6))}
             missing: #{inspect(MapSet.difference(before, withdrawn) |> Enum.take(6))}
             """
    end
  end

  defp settle(scope) do
    {:ok, _pid} = IncrementalGraph.ensure_projecting(scope)
    :ok = IncrementalGraph.settle(scope.active_project_id)
  end

  # The event path's edges at this vantage, as node-key pairs.
  defp edges(scope) do
    ctx = Preloader.topology_context(scope)
    source = {GraphStore.event_target(), {GraphStore.event_edges(), Edge}}
    {_nodes, edges} = Projection.load(scope, ctx, source: source)
    MapSet.new(edges)
  end

  defp kicks_off?(edges, story_id, component_id) do
    Enum.any?(
      edges,
      &match?(%{from: {"story", ^story_id, _}, to: {"component", ^component_id, _}}, &1)
    )
  end

  defp joins?(edges, from_component_id, to_component_id) do
    Enum.any?(
      edges,
      &match?(
        %{from: {"component", ^from_component_id, _}, to: {"component", ^to_component_id, _}},
        &1
      )
    )
  end

  defp component(scope, module_name) do
    {:ok, component} =
      Components.create_component(scope, %{
        name: module_name,
        type: "context",
        module_name: module_name,
        description: "#{module_name}, for the edges"
      })

    component
  end
end
