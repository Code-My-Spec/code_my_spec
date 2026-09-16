defmodule CodeMySpecSpex.Story1062.Criterion3430Spex do
  @moduledoc """
  Story 1062 — The graph recomputes as observations arrive.
  Criterion 3430 — A component going away takes its requirements with it.

  Rule: requirements appear and disappear with the entities they belong to, not
  with the freshness of their answers.

  ## The direction that fails quietly

  Criterion 3429 is the same rule arriving. This is it departing, and the two
  are not symmetric in consequence. A missing row is loud — an agent is never
  handed work it can see in the backlog, and somebody notices. A row that
  outlived its component is silent and worse: the graph goes on asking for a
  spec, a test and an implementation for a module nobody will write again, and
  the requirement can never be satisfied because there is nothing to satisfy it
  with. An agent handed that work has no way to finish it.

  `delete_departed/4` is the mechanism, and its own comment records how narrow
  the correct behaviour is. It reaps rows for entities the computation *visited*
  rather than entities it *produced* — because a component that was loaded and
  yielded nothing is not a component nobody looked at, and treating them alike
  either strands rows forever or deletes rows that are simply being kept.

  ## Retired the way a component actually retires

  There is no `delete_component` an agent can call, and issue `c23f4427`
  records that as a real gap. What there is, is the file path: components are
  projections of files, so a component stops existing when nothing names its
  module any more. `ComponentSync.cleanup_removed/3` prunes exactly that, and
  its comment carries the data-loss bug it was written against — a per-harness
  read would have made every sync delete every component whose spec lives only
  in another checkout, with three worktrees taking turns deleting each other's
  architecture.

  So the scenario deletes the spec and the implementation and syncs, which is
  what retiring a component looks like from outside.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.GraphGivens
  import CodeMySpecSpex.GraphReadHelpers

  alias CodeMySpecSpex.Fixtures

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "A retired component stops being asked for" do
    scenario "a component's files are removed and the project is synced" do
      given_ :two_independent_sibling_schemas

      given_ "a graph that carries both siblings' requirements", context do
        _warm = read_settled_graph(context)

        {:ok, Map.put(context, :before, read_settled_graph(context))}
      end

      when_ "one sibling's spec and implementation are deleted and the project syncs",
            context do
        :ok = Fixtures.delete_env_file(context.environment, "lib/catalog/product.ex")

        :ok =
          Fixtures.delete_env_file(
            context.environment,
            ".code_my_spec/spec/catalog/product.spec.md"
          )

        sync(context)

        {:ok, Map.put(context, :after, read_settled_graph(context))}
      end

      then_ "it was being asked for before", context do
        carried = requirements_for(context.before, context.sibling_a.id)

        refute carried == [],
               """
               The premise did not hold: this component had no requirements to
               lose, so the assertion below passes without anything being
               reaped.

               before: #{inspect(carried)}
               """

        {:ok, context}
      end

      then_ "and nothing asks for it now", context do
        carried = requirements_for(context.after, context.sibling_a.id)

        assert carried == [],
               """
               A component was retired and the graph still asks for work on it.

               Nothing names that module any longer, so there is no file for a
               spec to be written into and no module for a test to exercise.
               The requirement cannot be satisfied by anything an agent is able
               to do — it is work with no way to finish, and it will be offered
               for as long as the rows survive.

               still asking for: #{inspect(carried)}
               """

        {:ok, context}
      end

      then_ "while its sibling is untouched", context do
        carried = requirements_for(context.after, context.sibling_b.id)

        refute carried == [],
               """
               Retiring one component took the other's requirements with it.

               `delete_departed/4` reaps per entity. A reap that widened to the
               project would empty the graph on any removal, and every
               assertion above would still pass — "nothing asks for the retired
               component" is satisfied perfectly by a graph that asks for
               nothing at all.

               sibling carries: #{inspect(carried)}
               """

        {:ok, context}
      end
    end
  end

  defp requirements_for(graph, component_id) do
    (graph["nodes"] || [])
    |> Enum.filter(
      &(&1["entity_type"] == "component" and
          to_string(&1["entity_id"]) == to_string(component_id))
    )
    |> Enum.map(& &1["name"])
    |> Enum.sort()
  end
end
