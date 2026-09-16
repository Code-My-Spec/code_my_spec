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
  import CodeMySpecSpex.MainAgentHelpers, only: [designate_main_copy: 2]

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
        story =
          CodeMySpecSpex.StoryHelpers.create_story(context.scope,
            title: "Work in flight",
            description: "carried by a checkout that is not the running one"
          )

        # `preview_status` is the field, and "only sometimes matters" is literal:
        # `and_serving/2` short-circuits on an unpromoted story at a checkout
        # that is not the running one, so `serving/2` never reads it there. It
        # matters here because this checkout *is* the running copy, which is one
        # of the two routes that reach it.
        #
        # It replaces `commits_ahead_of_main`, which was the field this was
        # written about. That column is gone — a mirror of git nothing decided
        # on, hashed into every story's fingerprint so a keystroke anywhere
        # reconsidered every story in the project.
        reply = join_working_copy(context, "/tmp/spex-3232", "the running copy")
        :ok = designate_main_copy(context, reply.working_copy_id)
        :ok = CodeMySpecSpex.Fixtures.record_preview_status(reply.working_copy_id, "down")

        # Read as this checkout, because the claim is about this checkout. A
        # read that names no copy gets the UI's blended vantage, where the
        # answer does not depend on any one checkout.
        _cold = read_graph(context, reply.working_copy_id)

        {:ok,
         context
         |> Map.put(:working_copy_id, reply.working_copy_id)
         |> Map.put(:new_story, story)
         |> Map.put(:before, read_graph(context, reply.working_copy_id))}
      end

      when_ "the application comes back up and the checkout reports it", context do
        :ok = CodeMySpecSpex.Fixtures.record_preview_status(context.working_copy_id, "serving")
        {:ok, context}
      end

      then_ "the graph does not answer from the computation made while it was down",
            context do
        after_merge = read_graph(context, context.working_copy_id)

        before_reason =
          reason_for(context.before, "code_on_running_copy", :story, context.new_story.id)

        reason = reason_for(after_merge, "code_on_running_copy", :story, context.new_story.id)

        assert before_reason =~ "not answering",
               """
               The premise did not hold: a running copy whose application is
               down must say so, or coming back up has nowhere to show up.

               before: #{inspect(before_reason)}
               """

        # The reason, not the verdict, because the obstacle the checker names is
        # what this criterion is about.
        refute reason =~ "not answering",
               """
               The application came back up and the graph still says it is not
               answering.

               No file changed here — only `preview_status` — so a files digest
               cannot see this. If the fingerprint does not cover it, the cached
               graph keeps refusing the story with the reason it computed while
               the application was down, and QA is held away from an application
               that is serving.

               The claim is the verdict, not a clock: `checked_at` is
               second-resolution, so a write and the recompute answering it
               read as the same instant.

               before: #{inspect(before_reason)}
               after:  #{inspect(reason)}
               """

        {:ok, context}
      end
    end
  end
end
