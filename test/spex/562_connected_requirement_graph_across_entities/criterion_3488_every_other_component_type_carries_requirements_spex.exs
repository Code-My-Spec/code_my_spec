defmodule CodeMySpecSpex.Story562.Criterion3488Spex do
  @moduledoc """
  Story 562 — Connected Requirement Graph Across Entities.
  Criterion 3488 — Every component type other than infrastructure carries
  requirements.

  Rule: infrastructure produces no requirements — it is the project's plumbing,
  not its work to build.

  Criterion 3486 says infrastructure is exempt. This says it is the *only* thing
  exempt, which is the half that keeps the rule from spreading. An exemption
  nobody bounds is an exemption that grows: a type added with no template, a
  fall-through clause quietly returning `[]`, and the graph gets smaller while
  reading as progress.

  The bound cannot be read off `Components.Registry`, which is the reason to
  assert it rather than document it. `infrastructure` is not in that table at
  all — it exists only as one clause of `graph_for_type/1` — so the type list
  and the exempt list are maintained in different places and nothing connects
  them. A sweep is how you ask.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.GraphGivens

  alias CodeMySpecSpex.GraphAssertions

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Infrastructure is the only type the graph is silent about" do
    scenario "one component of every type, and only the plumbing is empty" do
      given_ :one_component_of_every_type

      when_ "the engineer opens the requirements graph", context do
        {:ok, _live, html} =
          live(
            context.conn,
            "/app/projects/#{context.project.id}/requirements/graph?preload=true"
          )

        {:ok, Map.put(context, :graph, GraphAssertions.extract_graph!(html))}
      end

      then_ "every type but infrastructure asks for work", context do
        empty =
          context.swept_types
          |> Enum.reject(&(&1 == :infrastructure))
          |> Enum.filter(&(requirements_for(context, &1) == []))

        assert empty == [],
               """
               #{length(empty)} component type(s) carry no requirements at all.

               Only infrastructure is exempt. A type the graph is silent about
               is a type no agent will ever be asked to build, and nothing else
               reports it — the components simply sit there looking finished.

               Silent: #{inspect(empty)}
               """

        {:ok, context}
      end

      then_ "and infrastructure is the one that does not", context do
        carried = requirements_for(context, :infrastructure)

        assert carried == [],
               """
               Infrastructure carries requirements, so the sweep above proves
               the wrong thing — it becomes "every type carries requirements",
               which is a different rule and not this one.

               Carried: #{inspect(carried)}
               """

        {:ok, context}
      end
    end
  end

  # The rendered node carries its entity in the key — `component_<id>_<name>`,
  # with the dashes stripped — rather than as a field of its own.
  defp requirements_for(context, type) do
    component = Map.fetch!(context.swept_components, type)
    prefix = "component_" <> String.replace(component.id, "-", "") <> "_"

    context.graph["nodes"]
    |> Enum.filter(&String.starts_with?(&1["key"], prefix))
    |> Enum.map(&get_in(&1, ["attributes", "name"]))
    |> Enum.sort()
  end
end
