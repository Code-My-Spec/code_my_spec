defmodule CodeMySpecSpex.Story1063.Criterion3231Spex do
  @moduledoc """
  Story 1063 — A cached graph is never served after its inputs have moved.
  Criterion 3231 — A heartbeat changes nothing anyone can see.

  Rule: a value that changes on every heartbeat is not treated as a change of
  substance.

  The counterweight to the rest of this story. Everything else here is about
  the graph noticing a change; this is about it *not* noticing a non-change.
  Both failures are real and they pull against each other: cover too little and
  a verdict goes stale permanently, cover too much and the graph recomputes on
  every liveness report for as long as a harness is running.

  Measured while the fingerprint was being extended to cover working copies:
  hashing `git_state_at` by value would have invalidated the project's graph on
  every sync, because that column is stamped with the current time whether or
  not anything it describes moved. It is hashed as nil-or-not for exactly this
  reason — the checker asks whether a report has ever arrived, never when.

  Observed through `GET /api/projects/:project_name/requirements/graph`, which
  serves the *cached* graph with its `computed_at`. The markdown `/requirements`
  endpoint cannot answer this: it calls `compute_all/1` and so recomputes on
  every request by construction.

  Read as the checkout that reported, with `?working_copy=`. A read that names
  no copy gets the UI's blended vantage, where the fingerprint reads nothing
  about any particular checkout — so the graph would hold still here whatever
  the heartbeat carried, and the assertion would cost nothing. Naming the copy
  is what makes this a claim about the heartbeat rather than about the read.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.GraphReadHelpers

  import CodeMySpecSpex.WorkingCopyHelpers

  alias Ecto.Adapters.SQL.Sandbox

  setup :register_log_in_setup_account
  setup :setup_active_project

  # The join runs in a channel process of its own.
  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  @state %{ahead: 0, behind: 0, dirty: false}

  spex "A working copy reporting in does not move the graph" do
    scenario "the copy reports the same state twice" do
      given_ "a checkout that has reported its state, and a graph that has been served",
             context do
        reply = join_working_copy(context, "/tmp/spex-3231", "the checkout")
        :ok = CodeMySpecSpex.Fixtures.record_git_state(reply.working_copy_id, @state)

        # Read once to put a graph in the cache, then take the reading that
        # matters. The first read of a cold cache computes and stores, and
        # answers `computed_at: nil` while doing it — so measuring from that
        # one compares "no cached graph yet" against "a cached graph", which
        # is a difference this criterion is not about.
        _cold = read_graph(context, reply.working_copy_id)

        {:ok,
         context
         |> Map.put(:working_copy_id, reply.working_copy_id)
         |> Map.put(:before, read_graph(context, reply.working_copy_id))}
      end

      when_ "the checkout reports in again with nothing about it changed", context do
        :ok = CodeMySpecSpex.Fixtures.record_git_state(context.working_copy_id, @state)
        {:ok, context}
      end

      then_ "the graph still answers from the same computation", context do
        after_report = read_graph(context, context.working_copy_id)

        assert after_report["computed_at"] == context.before["computed_at"],
               """
               The graph was recomputed after a report that carried no change.

               A liveness timestamp advancing is not a change of substance. If
               `computed_at` moves here, something in the fingerprint is hashing
               a value that is stamped on every sync, and the graph will
               recompute on every heartbeat for as long as a harness runs.

               before: #{inspect(context.before["computed_at"])}
               after:  #{inspect(after_report["computed_at"])}
               """

        assert after_report["nodes"] == context.before["nodes"],
               "The graph's answer changed after a report that carried no change."

        {:ok, context}
      end
    end
  end
end
