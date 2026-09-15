defmodule CodeMySpecSpex.Story1062.Criterion3358Spex do
  @moduledoc """
  Story 1062 — The graph recomputes as observations arrive.
  Criterion 3358 — A cached answer and a fresh one describe the same graph.

  Earned rather than designed. QA on this story read the requirements graph page
  twice and got 2009 requirements computed and 1844 from the cache — stable
  across reads, back to 2009 on the next recompute, all under one `computed_at`
  (7a6b92e3). Two graphs wearing one timestamp.

  That is worth a criterion of its own because it is not covered by any other
  one here. The rest of this story is about the graph *moving* when it should;
  this is about the two ways of reading it agreeing, which nothing asserted.

  ## Why it could happen

  A miss answers with what it computed. A hit answers with `Projection.load/2` —
  the projection tables read back — and that is lossy by construction:
  `rehydrate/2` returns nil when `entity_for/2` cannot place a row's entity or
  `definition_for/2` cannot find its definition, and those rows are dropped.
  Nothing was wrong with either the write or the read, which is why it survived
  until a page put both numbers next to each other.

  `served_graph/3` already refused the empty case — a projection with no rows
  behind a publish that counted some is a write that did not land. It now
  refuses any shortfall, on the same reasoning: `node_count` is the publish's own
  claim about itself, so it is the one number a read cannot argue with.

  ## What this observes, and what it cannot

  Two reads of the page, the first computing and the second served from cache,
  reporting the same requirements. That is the criterion as written and it is
  what a person sees.

  It cannot manufacture the shortfall — a fixture project round-trips
  losslessly, and the failure needs rows the preloaded context cannot rebuild,
  which QA's project had 165 of and a fresh one has none. The adversarial case
  lives in `graph_cache_test.exs`, which deletes a projected row behind the
  cache's back so `node_count` over-claims, and is confirmed to fail with the
  guard removed. This spex is the surface; that test is the proof.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.GraphReadHelpers

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "The cache and the computation agree about the graph" do
    scenario "a reader is served from cache after computing" do
      given_ "a project whose graph has been computed", context do
        # The watcher computes on arrival, so by the time a spex runs there is
        # a graph. This used to say "not computed yet" and let the first read
        # do it — which is exactly the coupling story 1063 removed: a read that
        # computes is a read that hides a writer which announced nothing.
        {:ok, Map.put(context, :computed, read_settled_graph(context))}
      end

      when_ "it is read again", context do
        {:ok, Map.put(context, :cached, read_graph(context))}
      end

      then_ "both answers hold the same requirements", context do
        assert context.computed["served_from"] == "cache",
               "the graph should be answered from rows, not rebuilt by the reader"

        assert context.cached["served_from"] == "cache",
               "the second read should have been served the same rows"

        assert length(context.cached["nodes"]) == length(context.computed["nodes"]),
               """
               The cached read and the computation it came from describe
               different graphs.

               computed: #{length(context.computed["nodes"])} requirements
               cached:   #{length(context.cached["nodes"])} requirements

               Both readings are internally coherent, which is why this survived
               until a page showed them side by side under one timestamp. A
               reader comparing `computed_at` across reads to see whether the
               graph moved is then comparing two different answers, and an agent
               deciding from the smaller one is missing work that exists.
               """

        assert last_recompute(context.cached) == last_recompute(context.computed),
               "a cache hit should carry the timestamp of the computation it serves"

        {:ok, context}
      end
    end
  end
end
