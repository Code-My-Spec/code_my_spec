defmodule CodeMySpecSpex.Story1062.Criterion3359Spex do
  @moduledoc """
  Story 1062 — The graph recomputes as observations arrive.
  Criterion 3359 — A read that names no checkout keeps its own answer.

  Rule: a read with nothing pending does not force a recompute — for every
  reader, not only the one that computed last.

  ## Why this is a criterion and not a preference

  `Preloader.load/1` given a scope with no checkout reads every checkout's
  files together, and says so in as many words: "a file present in one and
  absent in another reads as present. Expected for the UI; an agent path here
  is a bug." That is a graph describing a tree which has never existed.

  Its cost is not only over-satisfaction. `Projection.vantage/1` resolves a
  reader with no checkout to the project's **default** working copy, and the
  write uses the same function — so the blend is stored where one checkout's
  answer belongs. Two readers write different graphs into one row-space, each
  read finds the other's, and `served_graph/3` correctly refuses a projection
  that does not match the count it published.

  Measured on this project, 2026-09-12: 348 full graph computes in one log,
  median 2.6s, p90 5.9s, max 14.8s — 116 of them triggered by stop hooks. The
  cockpit carries this component and re-renders on every turn the main agent
  takes, so the busiest page in the application recomputed the whole graph on
  every render, and an agent's turn could end in a timeout that named the
  network.

  ## Why it only bites one project

  `vantage/1` reads `project.default_working_copy_id`, which nothing in `lib/`
  writes — `WorkingCopies.designate_main/2`, the product operation, sets
  `working_copy.main` instead. Measured across the database: 8 projects have
  designated a main copy and **1 of 55** has `default_working_copy_id` set. On
  the other 54 a reader naming no checkout resolves to `nil`, writes to its own
  row-space and collides with nothing. The one project that has it set is the
  one whose page is slow.

  ## The shape that removes it

  Not "resolve the vantage earlier" but "do not offer the question". A working
  copy id required at the function boundary makes the blend unrepresentable
  rather than merely unasserted, and the edge resolves a checkout once before
  anything downstream can be called without one. `Preloader.load/1`'s nil
  clause already argues for its own removal: "a web view should read the
  default branch … At that point the question 'which harness is the UI showing'
  stops existing, and this clause can go."

  ## What this observes, and why it is not 3353 or 3358

  The node count a reader naming no checkout is given, against the count the
  default checkout is given. Equal means one checkout was described; larger
  means every checkout was at once.

  3353 asserts repeated reads do not recompute, and passes — every read in it
  names the same vantage, so there is nothing to disagree with. 3358 asserts a
  cached answer and a fresh one describe the same graph, and its own moduledoc
  records that it could not manufacture the shortfall: "a fixture project
  round-trips losslessly, and the failure needs rows the preloaded context
  cannot rebuild, which QA's project had 165 of and a fresh one has none."

  That inference is what let this live. The shortfall needs neither 165 nodes
  nor a large project — it needs two vantages, which fits in a fixture. Two
  earlier drafts of this criterion passed, and both failed the same way 3358
  did, by not establishing what they assumed:

  - a file present in only one checkout — no component behind it, so it
    contributed no node and both readers computed the same graph;
  - `designate_main/2` alone — it does not write the field `vantage/1` reads,
    so the reader naming none resolved to `nil` and shared no row-space.

  Both were caught by printing the state rather than by reasoning about it.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.GraphReadHelpers

  alias CodeMySpecSpex.Fixtures

  defp again_served_from_cache?(context), do: context.again["served_from"] == "cache"

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "A reader that names no checkout keeps its own answer" do
    scenario "a project whose checkouts do not hold the same work" do
      given_ "two checkouts, one of them the default, and work belonging to the other",
             context do
        main = Fixtures.live_agent_scope(context.scope, label: "the main checkout")
        other = Fixtures.live_agent_scope(context.scope, label: "a worktree off it")

        :ok = Fixtures.designate_main(context.scope, main.active_working_copy_id)

        # The smallest thing that makes two vantages disagree. `Preloader.load/1`
        # narrows stories to those assigned to this checkout or to none; with no
        # checkout to narrow by it takes every story in the project. So this one
        # is in a blended reader's graph and absent from the main checkout's.
        Fixtures.released_story(context.scope, "Work that belongs to the other checkout",
          working_copy: other.active_working_copy_id
        )

        {:ok, Map.put(context, :main_copy_id, main.active_working_copy_id)}
      end

      when_ "it is answered, a checkout reads, and it asks again", context do
        _cold = read_graph(context)
        warmed = read_graph(context)
        _checkout = read_graph(context, context.main_copy_id)
        again = read_graph(context)

        {:ok, context |> Map.put(:warmed, warmed) |> Map.put(:again, again)}
      end

      then_ "it is served the answer it already had", context do
        assert again_served_from_cache?(context),
               """
               A reader that named no checkout was made to recompute by one that did.

               Both had answers. Neither input moved. They were writing into the
               same rows: `Projection.vantage/1` resolved the reader with no
               checkout to the default copy, so the two overwrote each other and
               every read found a projection that did not match the count it
               published.

               Nothing here is stale. They disagreed, and went on disagreeing,
               and the cost was a full recompute on every read — 348 of them in
               one log on this project, median 2.6s, max 14.8s, 116 from stop
               hooks. The cockpit carries this component and re-renders on every
               turn the main agent takes.

               warmed: #{inspect(context.warmed["served_from"])}
               again:  #{inspect(context.again["served_from"])}
               """

        {:ok, context}
      end

      then_ "and it still holds the same requirements", context do
        assert length(context.again["nodes"]) == length(context.warmed["nodes"]),
               """
               The reader was handed a different graph than the one it had.

               A recompute that answers with fewer requirements than the cached
               answer it replaced is the shortfall criterion 3358 is about,
               reached by the route that produces it rather than manufactured.

               before: #{length(context.warmed["nodes"])} requirements
               after:  #{length(context.again["nodes"])} requirements
               """

        {:ok, context}
      end
    end
  end
end
