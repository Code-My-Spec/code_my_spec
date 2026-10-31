defmodule CodeMySpecSpex.Story1062.Criterion3422Spex do
  @moduledoc """
  Story 1062 — The graph recomputes as observations arrive.
  Criterion 3422 — Stored requirements are trusted rather than counted.

  Rule: an observation costs work in proportion to what it changed, not to the
  size of the project.

  ## What was there before, and what it cost

  `requirement_graphs` held a `node_count` beside the fingerprint, and a read
  compared it against the rows it had just loaded — a short read meant refuse
  and recompute. The count existed only to distrust the rows next to it, and it
  was wrong for a reason nothing in the read could see: `GraphCache` keyed its
  row on the raw `active_working_copy_id` while the rows were keyed on
  `Projection.vantage/1`, which resolved nil to the default checkout. A browser
  reader counted 2064 against a checkout holding 2021, refused, and recomputed.
  Every single read.

  So this asserts the absence of that: a reader with nothing pending is answered
  from what is stored, and answering does not cost a recompute.

  ## What it reads

  `served_from` and the watcher's `last_recompute`, both of which the graph
  endpoint publishes. Together they say the two halves the criterion needs —
  where the answer came from, and that producing it moved nothing. Neither is
  inferable from the nodes themselves, which is why the endpoint reports them.

  Deliberately not `computed_at`: it says a pass ran, not that this read caused
  one, and a pass triggered by something else between the two reads would move
  it while this claim still held.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.GraphReadHelpers
  import CodeMySpecSpex.SharedGivens

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "A read trusts the rows it finds", criterion: 1362 do
    scenario "Stored requirements are trusted rather than counted" do
      given_ :synced_context_component

      given_ "a graph that has been computed and stored", context do
        # `read_settled_graph/1` reads twice on purpose: the first read settles
        # the projector, the second is answered from what it settled.
        graph = read_settled_graph(context)

        assert graph["nodes"] != [],
               "there is nothing stored to trust; the rest of this measures an empty graph"

        {:ok, Map.put(context, :before, graph)}
      end

      when_ "a reader asks for it again with nothing pending", context do
        {:ok, Map.put(context, :after, read_graph(context))}
      end

      then_ "the answer came from what was stored", context do
        assert context.after["served_from"] == "cache",
               """
               The graph reported `served_from: #{inspect(context.after["served_from"])}`.

               "empty" means this vantage holds no rows at all, which is a
               different and more alarming answer than a cache miss — nobody has
               computed it, rather than this read having built it.
               """

        {:ok, context}
      end

      then_ "and answering it did not cost a recompute", context do
        assert recompute_stamp(context.after) == recompute_stamp(context.before),
               """
               A read with nothing pending moved the watcher's last recompute
               from #{inspect(recompute_stamp(context.before))} to
               #{inspect(recompute_stamp(context.after))}.

               The read recomputed to satisfy itself the stored rows were
               complete. That is the count-and-distrust behaviour this criterion
               exists to rule out: it made every browser read rebuild the whole
               project, because the counter and the rows were keyed differently
               and the comparison could never succeed.
               """

        {:ok, context}
      end

      then_ "and it answered with the same requirements it had stored", context do
        assert names(context.after) == names(context.before),
               "the rows served changed between two reads with no observation between them"

        {:ok, context}
      end
    end
  end

  defp recompute_stamp(graph), do: get_in(graph, ["watcher", "last_recompute"])

  defp names(graph) do
    (graph["nodes"] || [])
    |> Enum.map(&{&1["entity_type"], to_string(&1["entity_id"]), &1["name"]})
    |> Enum.sort()
  end
end
