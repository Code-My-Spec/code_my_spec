defmodule CodeMySpecSpex.Story1062.Criterion3490Spex do
  @moduledoc """
  Story 1062 — The graph recomputes as observations arrive.
  Criterion 3490 — A container left empty by configuration still carries its
  children's requirements.

  Rule: the graph can tell an entity it computed and found empty from one it
  has never computed.

  ## An empty container is not an empty subtree

  Criterion 3489 stops an entity that holds no rows being counted as
  never-computed on every pass. This is the distinction that makes that
  subtraction safe to define at all: "holds no rows of its own" and "has no
  work under it" have to stay different things, and one component type is
  deliberately the first without being the second.

  With `require_specs` and `require_reviews` off, `live_context_graph/0` keeps
  one definition — `implementation_file`, at `:child` scope — so the live
  context itself holds nothing and every LiveView beneath it holds its own
  implementation. Measured across all eighteen component types with specs,
  reviews and unit tests off: every type keeps `implementation_file`,
  `live_context` is the only one that keeps it at `:child` scope, and
  `infrastructure` the only one that keeps nothing at all. So this is the only
  shape in the system where an empty container sits over a working child, and
  it is the shape that would catch that template losing its child definition —
  which would take a whole subtree of LiveViews quiet with it.

  ## What it does not claim, and why the shape looks like it should

  The LiveView arrives after the container so the pass has to place it rather
  than find it already placed. That is not a control on the subtraction, and it
  cannot be: a component arriving moves the topology fingerprint, which sends
  the pass down the full-recompute path before `appeared` is consulted at all.
  Any component that is not genuinely barren therefore already has rows, which
  is what bounds the subtraction — not this spec. Verified by widening the
  predicate to swallow the whole family: this stayed green, and that is the
  right answer rather than a gap in it.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.GraphGivens

  alias CodeMySpecSpex.{Fixtures, GraphAssertions}

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "An empty namespace is not an empty subtree" do
    scenario "a LiveView arrives under a container that has nothing of its own" do
      given_ :live_context_under_a_config_that_empties_it

      when_ "a second LiveView is written beneath it and the project is synced", context do
        context
        |> write_component_specs([{"MyAppWeb.BookingLive.Show", :liveview, []}])
        |> sync()

        arrival =
          Fixtures.get_component_by_module_name(context.scope, "MyAppWeb.BookingLive.Show")

        {:ok, _live, html} =
          live(
            context.conn,
            "/app/projects/#{context.project.id}/requirements/graph?preload=true"
          )

        {:ok,
         context
         |> Map.put(:arrival, arrival)
         |> Map.put(:graph, GraphAssertions.extract_graph!(html))}
      end

      then_ "the live context carries nothing of its own", context do
        carried = requirements_for(context.graph, context.live_context.id)

        assert carried == [],
               """
               The live context carries requirements under a configuration that
               removed every one its template defines for itself.

               This is the premise the next assertion tests against, so getting
               it wrong makes that one vacuous rather than wrong: if the
               container is not empty here, nothing in this scenario is a
               container that `barren_components/2` would subtract.

               Carried: #{inspect(carried)}
               """

        {:ok, context}
      end

      then_ "the LiveView that just arrived carries the work", context do
        carried = requirements_for(context.graph, context.arrival.id)

        assert "implementation_file" in carried,
               """
               A LiveView that arrived under the emptied container was never
               given any requirements.

               `live_context_graph/0` keeps `implementation_file` at `:child`
               scope under exactly this configuration, so the work did not go
               away when the container emptied — it is the children's. Skipping
               it as barren subtracts a family where only a namespace is empty,
               and nothing reports that: the component renders with no
               outstanding work, which is the shape of finished.

               Carried: #{inspect(carried)}
               """

        {:ok, context}
      end

      then_ "and the ordinary component beside them still carries its own", context do
        carried = requirements_for(context.graph, context.ordinary.id)

        refute carried == [],
               """
               The ordinary context carries nothing either, so both assertions
               above hold against a graph that computed nothing at all.
               """

        {:ok, context}
      end
    end
  end

  # The rendered node carries its entity in the key — `component_<id>_<name>`,
  # with the dashes stripped — rather than as a field of its own.
  defp requirements_for(graph, component_id) do
    prefix = "component_" <> String.replace(component_id, "-", "") <> "_"

    graph["nodes"]
    |> Enum.filter(&String.starts_with?(&1["key"], prefix))
    |> Enum.map(&get_in(&1, ["attributes", "name"]))
    |> Enum.sort()
  end
end
