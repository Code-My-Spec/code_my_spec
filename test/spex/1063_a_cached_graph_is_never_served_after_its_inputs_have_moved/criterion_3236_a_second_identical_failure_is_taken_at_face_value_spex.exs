defmodule CodeMySpecSpex.Story1063.Criterion3236Spex do
  @moduledoc """
  Story 1063 — A cached graph is never served after its inputs have moved.
  Criterion 3236 — A second identical failure is taken at face value.

  Rule: a domain event is trusted; the graph does not re-verify that something
  really changed.

  The argument for trusting events rather than hashing what we already know we
  wrote. A second QA attempt that fails exactly as the first one did is,
  strictly, no change in the graph's answer — and computing that fact costs
  more than acting on it. The update touches the requirements one attempt bears
  on; being wrong about "did anything really change" therefore costs a couple
  of requirements, not a whole-project graph.

  This is the criterion that would justify deleting the fingerprint over owned
  objects entirely: the drift objection only bites when a redundant event is
  expensive, and incremental updates make it cheap.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.GraphReadHelpers

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Qa.Tools.SubmitQaResult

  setup :register_log_in_setup_account
  setup :setup_active_project
  setup :setup_qa_story_task

  spex "An identical second attempt is still an event" do
    scenario "the same failure is recorded twice" do
      given_ "a failed QA attempt already recorded, and a graph that has been served",
             context do
        # A `fail` submission is refused without at least one issue id: "a
        # non-pass result with an empty issue_ids list is dead work - the
        # failure disappears the moment your session ends". Both attempts cite
        # the same issue, which is what makes them identical.
        issue = CodeMySpecSpex.Fixtures.issue_fixture(context.scope)
        context = Map.put(context, :issue_id, issue.id)

        submit(context, context.task_id, "fail")

        # A task completes when it is submitted against, so a second attempt
        # needs a second task on the same story. Submitting twice against one
        # task is refused, which would make this scenario vacuous - the graph
        # cannot move for an attempt that was never recorded.
        {_story, second_task_id, _session} =
          CodeMySpecSpex.Fixtures.qa_story_task_fixture(context.scope, story: context.story)

        {:ok,
         context
         |> Map.put(:second_task_id, second_task_id)
         |> Map.put(:before, read_settled_graph(context))}
      end

      when_ "a second attempt fails in exactly the same way", context do
        submit(context, context.second_task_id, "fail")
        {:ok, context}
      end

      then_ "the graph does not answer from the computation made before it", context do
        after_second = read_graph(context)

        refute last_recompute(after_second) == last_recompute(context.before),
               """
               The second identical failure did not reach the graph.

               If the graph first computes whether anything really changed, an
               identical attempt looks like no change and is dropped. That is
               the behaviour this criterion exists to reject: the event is
               trusted, and acting on a redundant one costs the requirements
               that attempt bears on rather than a whole-project graph.

               This is the one criterion here that cannot claim a verdict: an
               identical attempt changes no answer and no `checked_at` by
               construction — that is what makes it identical. What it must
               still do is cause a pass, and the watcher's own clock is the
               only thing that records one at better than second resolution.

               last_recompute before: #{inspect(last_recompute(context.before))}
               last_recompute after:  #{inspect(last_recompute(after_second))}
               """

        {:ok, context}
      end
    end
  end

  defp submit(context, task_id, status) do
    frame = %Frame{assigns: %{current_scope: context.scope}}

    {:reply, response, _frame} =
      SubmitQaResult.execute(
        %{
          task_id: task_id,
          status: status,
          scenarios: [%{name: "smoke", status: status, observation: "the same observation"}],
          issue_ids: [context.issue_id]
        },
        frame
      )

    # A rejected submit would make the whole scenario vacuous — "the graph did
    # not move" is trivially true if nothing was recorded. Fail here instead,
    # where the reason is visible.
    refute response.isError,
           "submit_qa_result was rejected, so this scenario never recorded an attempt:\n" <>
             inspect(response)

    :ok
  end

end
