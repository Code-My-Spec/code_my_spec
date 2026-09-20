defmodule CodeMySpecSpex.Story1062.Criterion3472Spex do
  @moduledoc """
  Story 1062 — The graph recomputes as observations arrive.
  Criterion 3472 — A finding swapped for a different one is a different answer.

  Rule: what a requirement was computed from is the findings themselves, not
  how many there were.

  ## The one case a count cannot see

  Every other freshness criterion on this story can be satisfied by a cheap
  stamp. A finding appearing takes a component from zero to one; a finding
  being fixed takes it from one to zero. Both move a count, so both move a
  stamp built on one, and the graph looks correct.

  This is the case that separates them. One finding is corrected and a
  different rule fires in the same component in the same pass — the population
  is one before and one after, and a stamp that hashes the size of it does not
  move. The component is then never reconsidered: `stale_entities/3` compares
  the stamp, finds it equal, and the answer the graph serves goes on naming a
  finding that has been fixed while the one that is actually there is invisible.

  It is the quiet version of the failure, which is why it is worth its own
  criterion. Nothing errors, no count is wrong, and the only symptom is an
  agent sent to fix something that is already correct.

  ## What it observes

  `inputs_fingerprint` — the stamp `stale_entities/3` actually compares — read
  off the graph the same way [[criterion 3427]] reads it, which is what makes
  the two hold the same mechanism to the same account.

  Asserted together with the count staying at one. Without that half, a passing
  run would be indistinguishable from a stamp that moved because the number of
  findings changed, which is the very thing this criterion exists to rule out.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.GraphGivens
  import CodeMySpecSpex.GraphReadHelpers

  alias CodeMySpecSpex.Fixtures

  setup :register_log_in_setup_account
  setup :setup_active_project

  @source "credo"

  @moduledoc_finding %{
    message: "Modules should have a @moduledoc tag.",
    file_path: "lib/catalog/product.ex",
    line: 1
  }

  @nesting_finding %{
    message: "Function body is nested too deep (max_nesting is 2).",
    file_path: "lib/catalog/product.ex",
    line: 14
  }

  spex "A requirement records the findings it was computed from, not their number" do
    scenario "one credo finding is corrected and a different rule fires in the same component" do
      given_ :two_independent_sibling_schemas

      given_ "a component whose only credo finding is a missing moduledoc", context do
        :ok =
          Fixtures.replace_problems(context.scope, context.sibling_a.id, @source, [
            @moduledoc_finding
          ])

        _warm = read_settled_graph(context)
        before = read_settled_graph(context)

        refute is_nil(stamp(before, context.sibling_a.id)),
               "the component carries no stamp at all, so there is nothing for this " <>
                 "criterion to observe moving"

        {:ok, Map.put(context, :before, before)}
      end

      when_ "that finding is corrected and a different rule fires in the same component",
            context do
        :ok =
          Fixtures.replace_problems(context.scope, context.sibling_a.id, @source, [
            @nesting_finding
          ])

        {:ok, Map.put(context, :after, read_settled_graph(context))}
      end

      then_ "that component's requirements are recomputed", context do
        before_stamp = stamp(context.before, context.sibling_a.id)
        after_stamp = stamp(context.after, context.sibling_a.id)

        assert after_stamp != before_stamp,
               """
               A component's only finding was swapped for a different one and
               its requirements record the same sources as before.

               The population never changed size — one finding before, one
               after — so a stamp built on how many there are cannot tell these
               two states apart. `stale_entities/3` compares this value, finds
               it unchanged, and never reconsiders the component again.

               The answer the graph goes on serving names the finding that was
               fixed. Nothing errors and no count is wrong; an agent is simply
               sent to correct something that is already correct.

               before: #{inspect(before_stamp)}
               after:  #{inspect(after_stamp)}
               """

        {:ok, context}
      end

      then_ "and the answer it serves is not the one the count would have given", context do
        assert count_of(context.before, context.sibling_a.id) ==
                 count_of(context.after, context.sibling_a.id),
               """
               The two states differ in how many requirements the component
               carries, so the stamp asserted above could have moved for that
               reason alone.

               This half is what makes the other half mean anything: the
               criterion is about a *swap*, and a swap that changed the size of
               the population would be the ordinary case every other freshness
               rule already covers.

               before: #{count_of(context.before, context.sibling_a.id)} requirement(s)
               after:  #{count_of(context.after, context.sibling_a.id)} requirement(s)
               """

        {:ok, context}
      end

      then_ "and the component that neither finding touched is left alone", context do
        assert stamp(context.after, context.sibling_b.id) ==
                 stamp(context.before, context.sibling_b.id),
               """
               A sibling nothing was recorded against had its requirements
               recomputed too.

               A stamp that moves on every component whenever any component's
               findings change is trivially able to pass the assertion above,
               and it is the whole-project recompute this story exists to end.

               before: #{inspect(stamp(context.before, context.sibling_b.id))}
               after:  #{inspect(stamp(context.after, context.sibling_b.id))}
               """

        {:ok, context}
      end
    end
  end

  # One component's recorded sources, taken from any requirement it carries —
  # they are stamped per entity, so every row for the component answers the same
  # and the first is as good as the last.
  defp stamp(graph, component_id) do
    graph
    |> nodes_for(component_id)
    |> Enum.map(& &1["inputs_fingerprint"])
    |> List.first()
  end

  defp count_of(graph, component_id), do: length(nodes_for(graph, component_id))

  defp nodes_for(graph, component_id) do
    (graph["nodes"] || [])
    |> Enum.filter(
      &(&1["entity_type"] == "component" and
          to_string(&1["entity_id"]) == to_string(component_id))
    )
    |> Enum.sort_by(& &1["name"])
  end
end
