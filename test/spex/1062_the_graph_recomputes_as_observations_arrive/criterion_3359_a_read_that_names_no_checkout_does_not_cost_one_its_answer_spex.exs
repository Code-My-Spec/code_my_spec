defmodule CodeMySpecSpex.Story1062.Criterion3359Spex do
  @moduledoc """
  Story 1062 — The graph recomputes as observations arrive.
  Criterion 3359 — Every read of the graph is a read of one checkout.

  Rule: a requirement graph is a statement about a checkout, so a reader that
  names none is answered for one rather than for all of them at once.

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

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "A reader that names no checkout is answered for one" do
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

      when_ "the graph is read as the default checkout and by a reader naming none",
            context do
        as_checkout = read_graph(context, context.main_copy_id)
        naming_none = read_graph(context)

        {:ok,
         context
         |> Map.put(:as_checkout, as_checkout)
         |> Map.put(:naming_none, naming_none)}
      end

      then_ "it is given that checkout's graph, not every checkout's at once", context do
        assert length(context.naming_none["nodes"]) == length(context.as_checkout["nodes"]),
               """
               A reader that named no checkout was given a blend of all of them.

               A requirement graph is a statement about a checkout: these
               requirements are met *in this tree*. A reader handed the union of
               every checkout is told work is done because some other worktree
               did it — the over-satisfaction `Preloader`'s own moduledoc
               measured at 303 skipped specs.

               It is also why the cache cannot hold. `Projection.vantage/1`
               stores this blend where the default checkout's answer belongs, so
               the two readers overwrite each other and every read recomputes:
               a median of 2.6 seconds and a maximum of 14.8 on this project,
               116 of them triggered by stop hooks.

               as the default checkout: #{length(context.as_checkout["nodes"])} requirements
               naming no checkout:      #{length(context.naming_none["nodes"])} requirements
               """

        {:ok, context}
      end

      then_ "and having been answered once, it is answered again without recomputing",
            context do
        again = read_graph(context)

        assert again["served_from"] == "cache",
               """
               A read that named no checkout recomputed, having already been
               answered once with nothing written in between.

               This follows from the blend rather than being a separate fault:
               two vantages write different graphs into one row-space, so each
               read finds a projection that does not match the count it
               published and computes a new one. Nothing here is stale. They
               disagree, and go on disagreeing.

               served_from: #{inspect(again["served_from"])}
               """

        {:ok, context}
      end
    end
  end
end
