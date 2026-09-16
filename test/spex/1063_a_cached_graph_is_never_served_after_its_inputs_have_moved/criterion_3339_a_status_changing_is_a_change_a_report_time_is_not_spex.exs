defmodule CodeMySpecSpex.Story1063.Criterion3339Spex do
  @moduledoc """
  Story 1063 — A cached graph is never served after its inputs have moved.
  Criterion 3339 — A status changing is a change; a report time is not.

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
  and by what `Promotion.serving/2` reads: `preview_status` by value,
  `preview_checked_at` and `last_seen_at` not at all. The last two are stamped
  with the current time on every sync whether or not anything they describe
  moved, so hashing either by value would make every heartbeat a change and put
  a 4.4-second recompute on a loop for as long as a harness is running.

  ## The vehicle changed and the claim did not

  This was written against `commits_ahead_of_main`, with `git_state_at` as the
  report time. Those columns are gone — a mirror of git that nothing decided on,
  and hashing them into every story's fingerprint made one keystroke reconsider
  every story in the project.

  `preview_status` is the surviving input of exactly this shape: a value the
  graph genuinely reads, stamped beside a timestamp it must ignore. The pair is
  the point, not which pair.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.GraphReadHelpers
  import CodeMySpecSpex.MainAgentHelpers, only: [designate_main_copy: 2]
  import CodeMySpecSpex.WorkingCopyHelpers

  alias Ecto.Adapters.SQL.Sandbox

  setup :register_log_in_setup_account
  setup :setup_active_project

  # The join runs in a channel process of its own.
  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  @serving "serving"
  @down "down"

  spex "The graph tells a report apart from what it reports" do
    scenario "one checkout sends a heartbeat and then a real change" do
      given_ "a checkout that has reported, and a graph served from its vantage",
             context do
        story =
          CodeMySpecSpex.StoryHelpers.create_story(context.scope,
            title: "Reported on",
            description: "by a checkout that is not the running one"
          )

        # One checkout, and it is the running one. `running_copy_check/2` reaches
        # `serving/2` by two routes — the asking copy *is* main, or the story has
        # been promoted — and the first needs no promotion to set up. A checkout
        # that is neither would short-circuit before `preview_status` is read,
        # and then neither half of this scenario is about it.
        reply = join_working_copy(context, "/tmp/spex-3339", "the running copy")
        :ok = designate_main_copy(context, reply.working_copy_id)
        :ok = CodeMySpecSpex.Fixtures.record_preview_status(reply.working_copy_id, @serving)

        # Read as this checkout. Without `?working_copy=` the fingerprint reads
        # nothing about any particular copy, and both halves below would hold
        # for the same empty reason.
        _cold = read_graph(context, reply.working_copy_id)

        {:ok,
         context
         |> Map.put(:working_copy_id, reply.working_copy_id)
         |> Map.put(:new_story, story)
         |> Map.put(:before, read_graph(context, reply.working_copy_id))}
      end

      when_ "it reports the same status again, and then reports the app down",
            context do
        :ok = CodeMySpecSpex.Fixtures.record_preview_status(context.working_copy_id, @serving)
        after_heartbeat = read_graph(context, context.working_copy_id)

        :ok = CodeMySpecSpex.Fixtures.record_preview_status(context.working_copy_id, @down)

        {:ok, Map.put(context, :after_heartbeat, after_heartbeat)}
      end

      then_ "the heartbeat left the answer alone and the status did not",
            context do
        # The reason, not the verdict, so the two halves are compared the same
        # way — what changes is the obstacle the checker names, and the whole
        # point here is that a heartbeat changes nothing and a real change does.
        verdict = fn graph ->
          reason_for(graph, "code_on_running_copy", :story, context.new_story.id)
        end

        assert verdict.(context.after_heartbeat) == verdict.(context.before),
               """
               The answer moved after a report that carried no change.

               The checkout said "still serving" and the graph threw
               away an answer that was still correct. Every harness sends that
               report on a timer, so this is not one wasted recompute — it is a
               4.4-second recompute per checkout per sync, forever.

               before:          #{inspect(verdict.(context.before))}
               after heartbeat: #{inspect(verdict.(context.after_heartbeat))}
               """

        after_change = read_graph(context, context.working_copy_id)

        refute verdict.(after_change) == verdict.(context.after_heartbeat),
               """
               The graph answers the same way it did before the checkout
               reported its application down.

               The same column the heartbeat left alone has now changed by
               value, and that is the whole distinction: `preview_checked_at`
               moved both times, `preview_status` only this time. A
               fingerprint that cannot tell them apart is either blind to the
               copy — and `code_on_running_copy` keeps refusing a story the
               agent has already cleared — or blind to nothing, and recomputes
               on every heartbeat.

               after heartbeat: #{inspect(verdict.(context.after_heartbeat))}
               after change:    #{inspect(verdict.(after_change))}
               """

        {:ok, context}
      end
    end
  end
end
