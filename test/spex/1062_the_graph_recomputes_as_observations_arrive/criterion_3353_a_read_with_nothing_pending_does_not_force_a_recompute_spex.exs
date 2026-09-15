defmodule CodeMySpecSpex.Story1062.Criterion3353Spex do
  @moduledoc """
  Story 1062 — The graph recomputes as observations arrive.
  Criterion 3353 — A read with nothing pending does not force a recompute.

  Rule: a read with observations still pending recomputes before it answers.

  The limit on that rule, and the more important half of it. "Settle before
  answering" is one line away from "recompute on every read", which is the
  behaviour this whole story exists to replace — every graph computation in the
  application used to be triggered by a reader.

  So the settle has to be conditional on there being something to settle. With
  nothing pending, a read is a read: it answers from the cache and leaves the
  graph alone, however many times it is called.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.GraphReadHelpers

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Reading a settled graph does not recompute it" do
    scenario "the graph is read repeatedly with no observation in between" do
      given_ "a project whose graph has been served and nothing written since",
             context do
        {:ok, warm_graph(context) |> Map.put(:before, read_graph(context))}
      end

      when_ "the graph is read again several times", context do
        reads = for _ <- 1..5, do: read_graph(context)
        {:ok, Map.put(context, :reads, reads)}
      end

      then_ "every read answers from the same computation", context do
        stamps = context.reads |> Enum.map(&last_recompute/1) |> Enum.uniq()

        assert stamps == [last_recompute(context.before)],
               """
               Reading the graph recomputed it.

               Settling before answering has to be conditional on something
               being pending, or it becomes "recompute on every read" — which
               is the behaviour this story replaced. Reads are reads.

               expected every read to answer: #{inspect(last_recompute(context.before))}
               got: #{inspect(stamps)}
               """

        {:ok, context}
      end
    end
  end
end
