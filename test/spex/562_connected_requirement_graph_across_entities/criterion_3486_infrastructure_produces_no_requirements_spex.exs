defmodule CodeMySpecSpex.Story562.Criterion3486Spex do
  @moduledoc """
  Story 562 — Connected Requirement Graph Across Entities.
  Criterion 3486 — Infrastructure produces no requirements.

  Rule: infrastructure produces no requirements — it is the project's plumbing,
  not its work to build.

  This has always been true and nothing asserted it. Measured on this project
  2026-09-15: 11 infrastructure components, 0 with requirements. The exemption
  is categorical rather than incidental, so a template change that widened it
  would be invisible — a quieter graph reads as progress.

  The exemption is also *only* infrastructure, which is what criterion 3488
  sweeps. Worth saying because the dev project looks otherwise: its 7
  `live_context` components carry nothing either, and that is not an exemption
  but `require_specs` and `require_reviews` being off, emptying a template whose
  every node is a spec or a review. The two look identical from the outside and
  are different rules on different stories.

  The control matters as much as the claim. "Infrastructure carries no
  requirements" is satisfied by a graph that computed nothing at all, so the
  ordinary component beside it has to carry some.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.GraphGivens

  alias CodeMySpecSpex.GraphAssertions

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Infrastructure is not the project's work to build" do
    scenario "an infrastructure component carries no requirements" do
      given_ :context_with_infrastructure_sibling

      when_ "the engineer opens the requirements graph", context do
        {:ok, _live, html} =
          live(
            context.conn,
            "/app/projects/#{context.project.id}/requirements/graph?preload=true"
          )

        {:ok, Map.put(context, :graph, GraphAssertions.extract_graph!(html))}
      end

      then_ "nothing in the graph asks for work on it", context do
        carried = requirements_for(context.graph, context.infrastructure.id)

        assert carried == [],
               """
               An infrastructure component carries requirements.

               Infrastructure is the project's plumbing rather than its work —
               `architecture_designed` already exempts it from the orphan check
               on the same grounds. Asking an agent to write a spec, a test or a
               review for `Repo` or `Mailer` is work that does not exist.

               Carried: #{inspect(carried)}
               """

        {:ok, context}
      end

      then_ "and the ordinary component beside it does", context do
        carried = requirements_for(context.graph, context.ordinary.id)

        refute carried == [],
               """
               The ordinary component carries no requirements either, so the
               assertion above passes for the wrong reason.

               Both halves are needed: a graph that computed nothing satisfies
               "infrastructure is exempt" without the exemption existing.
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
