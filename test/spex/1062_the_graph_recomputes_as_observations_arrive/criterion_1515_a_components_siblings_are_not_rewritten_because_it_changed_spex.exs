defmodule CodeMySpecSpex.Story1062.Criterion3619Spex do
  @moduledoc """
  Story 1062 — The graph recomputes as observations arrive.
  Criterion 3619 — A component's siblings are not rewritten because it changed.

  Rule: a file changing rewrites no stored verdict. The copy's file verdicts
  are read from its files, so the next read follows the file.

  ## Measured on dev, and the arithmetic is exact

      01:19:08  [Files.ComponentSync] 1 components synced in 21ms (0 changed)
      01:19:10  recomputed 108 of 1547 — 105 entity(ies) stale
                                          (0/58 stories, 105/1145 components)

  **Zero changed**, by the sync's own count, and a hundred and five components
  went stale. Two files had moved, on one checkout, belonging to
  `CodeMySpec.Billing` and `CodeMySpecWeb.IntakeLive.Procedural`. Those two have
  101 and 3 siblings. 101 + 3 + their parents is the 105.

  `expand_component_families/2` is the multiplier. One test file changing under
  one child marks every child of that context stale.

  ## Why the family is expanded, and why that is not this

  It is not an accident, and the reason is real. `component_families/1` decides
  top-level from nested by asking whether each component's parent is *in the set
  it was given*, so a child narrowed to itself is classified top-level, runs its
  own template, and invents an `implementation_file` node the whole-project pass
  never produces. 549 of this project's components are nested; every one of them
  computed alone would do it.

  So the family has to be **in the context**. That is a different claim from
  every member's answer having moved, and the two were the same set. A sibling's
  file did not change, so its verdict cannot have — and rewriting its row stamps
  `checked_at` on a requirement nothing touched.

  The event path already draws this distinction: `recompute_entity/3` returns
  `{covered, nodes}` precisely because for a component the two differ. The
  batched pass collapsed them.

  ## What it observes

  `checked_at`, backdated first. The stamp is `truncate(:second)` into a
  precision-0 column, so a write inside one second is indistinguishable from
  none, and this scenario reads "nothing moved" as its own setup having failed.

  The event path stamps a row only when its answer moves, so the child's has
  to: the file that goes away is its implementation file — the fixture ships
  one per module — which flips `implementation_file`, the one requirement a
  component in this fixture carries. A sibling's file is still there, so its
  answer did not move, and a stamp on it is a row nothing touched being
  written anyway.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.GraphGivens
  import CodeMySpecSpex.GraphReadHelpers

  alias CodeMySpecSpex.Fixtures
  alias CodeMySpecSpex.GraphContentFixtures, as: Content

  # A copy's file verdicts: read from its files, never stored.
  @file_verdicts ~w(implementation_file bdd_specs_exist technical_strategy code_generation
    qa_journey_execute spex_boundary_ready architecture_designed qa_integration_plan)

  setup :register_log_in_setup_account
  setup :setup_active_project

  @moduletag timeout: 60_000

  spex "A file changing rewrites no stored verdict; the copy's graph reads it on the next read",
    criterion: 1515 do
    scenario "a context with three children, one of which loses its file" do
      given_ :context_with_three_children

      given_ "a settled graph, old enough to see a rewrite", context do
        :ok = Fixtures.settle_graph(context.scope)
        _warm = read_settled_graph(context)
        :ok = Fixtures.settle_graph(context.scope)
        :ok = Fixtures.backdate_requirement_freshness(context.scope)

        graph = read_graph(context)
        before = stored_stamps(graph)

        assert before != %{}, "nothing is stored, so no pass can leave anything alone"

        assert implementation(graph, context.child_schema.id) == true,
               "the premise did not hold: the child's implementation file is not read as present"

        {:ok, context |> Map.put(:before, before)}
      end

      when_ "one child's implementation file goes away", context do
        :ok =
          Fixtures.delete_env_file(
            context.execution_context,
            Content.impl_path(context.child_schema.module_name)
          )

        :ok = Fixtures.scan_working_copy(context.scope)
        :ok = Fixtures.settle_graph(context.scope)

        {:ok, Map.put(context, :after_graph, read_graph(context))}
      end

      then_ "the next read shows the child's file missing", context do
        assert implementation(context.after_graph, context.child_schema.id) == false,
               """
               A component's implementation file went away and the graph still
               reads it as present. The copy's file verdicts come from its
               files on read; this one did not follow them.
               """

        {:ok, context}
      end

      then_ "and no stored verdict was rewritten", context do
        rewritten =
          for {key, was} <- context.before,
              Map.get(stored_stamps(context.after_graph), key) != was,
              do: key

        assert rewritten == [],
               """
               A file went away and #{length(rewritten)} stored verdict(s) were
               rewritten: #{inspect(Enum.take(rewritten, 5))}.

               A file answers only the copy's file verdicts, which are read,
               never stored. Nothing the server stores reads a file, so a file
               changing is no reason to write anything.
               """

        {:ok, context}
      end
    end
  end

  defp implementation(graph, component_id),
    do: satisfaction_of(graph, "implementation_file", "component", component_id)

  # The verdicts the server stores, by when they were written.
  defp stored_stamps(graph) do
    for node <- graph["nodes"] || [], node["name"] not in @file_verdicts, into: %{} do
      {{node["entity_type"], to_string(node["entity_id"]), node["name"]}, node["checked_at"]}
    end
  end
end
