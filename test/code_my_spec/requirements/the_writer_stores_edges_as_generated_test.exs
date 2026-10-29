defmodule CodeMySpec.Requirements.TheWriterStoresEdgesAsGeneratedTest do
  @moduledoc """
  The projector stores every generated edge, a redundant one included, and
  readiness over them is readiness over their reduction.

  Readiness reads reachability (`RequirementGraph.actionable_from/3` blocks a
  node behind any unsatisfied ancestor), and a transitive reduction preserves
  reachability. So the write path does not reduce: a reduction is global,
  which is what made edges uncomputable per entity, and it bought no answer.
  Views reduce what they draw. This fails if the writer starts reducing again.
  """
  use CodeMySpecSpex.Case, async: true

  alias CodeMySpec.Components
  alias CodeMySpec.Configurations
  alias CodeMySpec.Requirements.Edges
  alias CodeMySpec.Requirements.IncrementalGraph
  alias CodeMySpec.Requirements.Preloader
  alias CodeMySpec.Requirements.Projection
  alias CodeMySpec.Requirements.RequirementGraph
  alias CodeMySpec.Requirements.Topology
  alias CodeMySpec.Stories

  setup :register_log_in_setup_account
  setup :setup_active_project

  test "a kickoff a longer path implies is stored, and readiness is unchanged by it", %{
    scope: scope
  } do
    accounts = component(scope, "Accounts")
    billing = component(scope, "Billing")

    {:ok, _dependency} =
      Components.create_dependency(scope, %{
        source_component_id: billing.id,
        target_component_id: accounts.id
      })

    {:ok, _story} =
      Stories.create_story(scope, %{
        ready_for_dev: true,
        title: "Invoice a customer",
        description: "As a clerk, I invoice a customer",
        acceptance_criteria: ["An invoice exists"],
        component_id: billing.id
      })

    settle(scope)
    {nodes, stored} = stored(scope)
    reduced = Topology.transitive_reduction(stored)

    redundant = MapSet.difference(MapSet.new(stored), MapSet.new(reduced))

    assert Enum.any?(
             redundant,
             &match?(%{from: {"story", _, _}, to: {"component", _, _}}, &1)
           ),
           """
           No stored story kickoff is implied by a longer path, so the writer reduced.

           Billing depends on Accounts, so the story's kickoff to Billing is
           implied by its kickoff to Accounts. Stored edges are kept as generated.
           """

    assert MapSet.new(stored) == generated(scope, nodes),
           "the stored edges should be exactly the generated ones"

    {:ok, ctx} = Preloader.load(scope)
    key = &{&1.entity_type, &1.entity_id, &1.name}

    assert Enum.map(RequirementGraph.actionable_from(nodes, stored, ctx), key) ==
             Enum.map(RequirementGraph.actionable_from(nodes, reduced, ctx), key)
  end

  defp settle(scope) do
    {:ok, _pid} = IncrementalGraph.ensure_projecting(scope)
    :ok = IncrementalGraph.settle(scope.active_project_id)
  end

  defp stored(scope), do: Projection.load(scope, Preloader.topology_context(scope))

  defp generated(scope, nodes) do
    config = Configurations.get_or_create(scope)

    scope
    |> Edges.generate(Preloader.topology_context(scope), config)
    |> Edges.among(MapSet.new(nodes, &Topology.node_key/1))
    |> MapSet.new()
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
