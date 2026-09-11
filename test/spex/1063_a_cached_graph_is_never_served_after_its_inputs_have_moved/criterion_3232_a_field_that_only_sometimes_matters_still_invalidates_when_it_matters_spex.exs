defmodule CodeMySpecSpex.Story1063.Criterion3232Spex do
  @moduledoc """
  Story 1063 — A cached graph is never served after its inputs have moved.
  Criterion 3232 — A field that only sometimes matters still invalidates when
  it matters.

  The other half of 3231, and the reason that one is not simply "ignore
  working copies". The same table carries a column stamped on every heartbeat
  and a column that only moves when the work does. Hashing all of it recomputes
  forever; hashing none of it serves a stale verdict forever.

  This is the case that made the distinction necessary. A promotion changes the
  commit count ahead of main without any file changing, so a files digest
  cannot see it — and the cached graph went on refusing the story with the
  reason it computed before the merge. That is the phantom PromoteWork a coding
  agent was handed repeatedly on 2026-09-11 after successfully promoting.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.GraphReadHelpers

  import CodeMySpecSpex.WorkingCopyHelpers

  alias Ecto.Adapters.SQL.Sandbox

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  spex "Work landing on main moves the graph" do
    scenario "the copy's commit count ahead of main changes" do
      given_ "a checkout with work main has not seen, and a graph that has been served",
             context do
        reply = join_working_copy(context, "/tmp/spex-3232", "the checkout")

        :ok =
          CodeMySpecSpex.Fixtures.record_git_state(reply.working_copy_id, %{
            ahead: 1,
            behind: 0,
            dirty: false
          })

        # Read as this checkout, because the claim is about this checkout.
        # `running_copy_check/2` asks whether the asking copy's work is on
        # main, and a read that names no copy is not asking that question of
        # anyone — it gets the UI's blended vantage, where the answer does not
        # depend on any one checkout's commit count.
        _cold = read_graph(context, reply.working_copy_id)

        {:ok,
         context
         |> Map.put(:working_copy_id, reply.working_copy_id)
         |> Map.put(:before, read_graph(context, reply.working_copy_id))}
      end

      when_ "the work lands on main and the checkout reports it", context do
        :ok =
          CodeMySpecSpex.Fixtures.record_git_state(context.working_copy_id, %{
            ahead: 0,
            behind: 0,
            dirty: false
          })

        {:ok, context}
      end

      then_ "the graph does not answer from the computation made before the merge",
            context do
        after_merge = read_graph(context, context.working_copy_id)

        refute after_merge["computed_at"] == context.before["computed_at"],
               """
               The graph answered from the computation it made before the work
               landed on main.

               No file changed here — only the commit count ahead of main — so a
               files digest cannot see this. If the fingerprint does not cover
               it, the cached graph keeps refusing the story with the reason it
               computed before the merge, which is the phantom PromoteWork an
               agent was handed repeatedly on 2026-09-11.
               """

        {:ok, context}
      end
    end
  end
end
