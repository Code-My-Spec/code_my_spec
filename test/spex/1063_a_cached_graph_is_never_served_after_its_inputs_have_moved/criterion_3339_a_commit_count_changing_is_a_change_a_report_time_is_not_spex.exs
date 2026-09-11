defmodule CodeMySpecSpex.Story1063.Criterion3339Spex do
  @moduledoc """
  Story 1063 — A cached graph is never served after its inputs have moved.
  Criterion 3339 — A commit count changing is a change; a report time is not.

  Rule: a working copy says so only when something other than its liveness
  timestamps changes.

  The two halves in one run, against one checkout, which is the only way to
  see that they are the same claim. 3231 has the heartbeat half and 3232 has
  the substance half, and each is satisfiable on its own by a fingerprint that
  is simply wrong in one direction — hash nothing about the copy and 3231
  passes forever; hash the whole row and 3232 passes while the graph
  recomputes on every sync. Neither of them can tell those apart, because
  neither sees the other's report.

  So the same checkout sends both reports, in order, and both readings come
  from the same cached row. The line the criterion is about is between them.

  What sits on each side is decided in `Preloader.working_copy_gate_inputs/2`,
  and by what `Promotion.in_sync/1` reads: the commit counts and `tree_dirty`
  by value, `git_state_at` as nil-or-not, `preview_checked_at` and
  `last_seen_at` not at all. The last three are stamped with the current time
  on every sync whether or not anything they describe moved, so hashing any of
  them by value would make every heartbeat a change and put a 4.4-second
  recompute on a loop for as long as a harness is running.
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

  @clean %{ahead: 0, behind: 0, dirty: false}
  @ahead %{ahead: 2, behind: 0, dirty: false}

  spex "The graph tells a report apart from what it reports" do
    scenario "one checkout sends a heartbeat and then a real change" do
      given_ "a checkout that has reported, and a graph served from its vantage",
             context do
        reply = join_working_copy(context, "/tmp/spex-3339", "the checkout")
        :ok = CodeMySpecSpex.Fixtures.record_git_state(reply.working_copy_id, @clean)

        # Read as this checkout. Without `?working_copy=` the fingerprint reads
        # nothing about any particular copy, and both halves below would hold
        # for the same empty reason.
        _cold = read_graph(context, reply.working_copy_id)

        {:ok,
         context
         |> Map.put(:working_copy_id, reply.working_copy_id)
         |> Map.put(:before, read_graph(context, reply.working_copy_id))}
      end

      when_ "it reports the same state again, and then reports work ahead of main",
            context do
        :ok = CodeMySpecSpex.Fixtures.record_git_state(context.working_copy_id, @clean)
        after_heartbeat = read_graph(context, context.working_copy_id)

        :ok = CodeMySpecSpex.Fixtures.record_git_state(context.working_copy_id, @ahead)

        {:ok, Map.put(context, :after_heartbeat, after_heartbeat)}
      end

      then_ "the heartbeat left the answer alone and the commit count did not",
            context do
        assert context.after_heartbeat["computed_at"] == context.before["computed_at"],
               """
               The graph was recomputed after a report that carried no change.

               The checkout said "still here, still clean" and the graph threw
               away an answer that was still correct. Every harness sends that
               report on a timer, so this is not one wasted recompute — it is a
               4.4-second recompute per checkout per sync, forever.

               before:          #{inspect(context.before["computed_at"])}
               after heartbeat: #{inspect(context.after_heartbeat["computed_at"])}
               """

        after_change = read_graph(context, context.working_copy_id)

        refute after_change["computed_at"] == context.after_heartbeat["computed_at"],
               """
               The graph answered from the computation it made before the
               checkout reported work ahead of main.

               The same column the heartbeat left alone has now changed by
               value, and that is the whole distinction: `git_state_at` moved
               both times, `commits_ahead_of_main` only this time. A
               fingerprint that cannot tell them apart is either blind to the
               copy — and `code_on_running_copy` keeps refusing a story the
               agent has already cleared — or blind to nothing, and recomputes
               on every heartbeat.

               after heartbeat: #{inspect(context.after_heartbeat["computed_at"])}
               after change:    #{inspect(after_change["computed_at"])}
               """

        {:ok, context}
      end
    end
  end
end
