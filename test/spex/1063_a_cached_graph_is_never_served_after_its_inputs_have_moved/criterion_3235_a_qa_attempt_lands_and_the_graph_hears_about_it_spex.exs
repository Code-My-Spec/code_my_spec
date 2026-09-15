defmodule CodeMySpecSpex.Story1063.Criterion3235Spex do
  @moduledoc """
  Story 1063 — A cached graph is never served after its inputs have moved.
  Criterion 3235 — A QA attempt lands and the graph hears about it.

  Rule: a domain object we own publishes an event when it changes.

  A QA attempt is ours. We write it, so the graph can be told rather than left
  to infer it — no polling, no hashing a table to discover a change we made
  ourselves. This is the case the whole trusted-event design is built on: the
  moment of the write is the moment we know, and anything later is inference
  about something already known.

  Observed through the cached graph's `computed_at`. If the attempt reached the
  graph, the served answer is a different computation from the one served
  before it.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.GraphReadHelpers

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Qa.Tools.SubmitQaResult

  setup :register_log_in_setup_account
  setup :setup_active_project
  setup :setup_qa_story_task

  spex "Recording a QA attempt moves the graph" do
    scenario "an attempt is submitted against a story" do
      given_ "a started qa_complete task and a graph that says QA is not done", context do
        before = read_settled_graph(context)

        assert satisfaction_of(before, "qa_complete", :story, context.story.id) == false,
               """
               The premise did not hold: this story's `qa_complete` is not
               already open, so submitting a passing attempt has nowhere to
               show up.

               qa_complete: #{inspect(satisfaction_of(before, "qa_complete", :story, context.story.id))}
               """

        {:ok, Map.put(context, :before, before)}
      end

      when_ "the agent submits the QA result", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, _response, _frame} =
          SubmitQaResult.execute(
            %{
              task_id: context.task_id,
              status: "pass",
              scenarios: [%{name: "smoke", status: "pass", observation: "ok"}],
              issue_ids: []
            },
            frame
          )

        {:ok, context}
      end

      then_ "the graph says QA is complete for that story", context do
        after_attempt = read_graph(context)

        assert satisfaction_of(after_attempt, "qa_complete", :story, context.story.id) == true,
               """
               A passing QA attempt was recorded and the graph still says this
               story's QA is not complete.

               A QA attempt is a domain object we own — we wrote it, so the
               graph should have been told. If the verdict is unchanged, the
               write published nothing and the graph is left to discover its own
               data by hashing a table.

               qa_complete before: #{inspect(satisfaction_of(context.before, "qa_complete", :story, context.story.id))}
               qa_complete after:  #{inspect(satisfaction_of(after_attempt, "qa_complete", :story, context.story.id))}
               """

        {:ok, context}
      end
    end
  end
end
