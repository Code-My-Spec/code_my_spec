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
      given_ "a started qa_complete task and a graph that has been served", context do
        # Warm the cache first. A cold read computes, stores, and answers
        # `computed_at: nil` while doing it, so measuring from that one compares
        # "no cached graph" against "a cached graph" rather than two answers.
        _cold = read_graph(context)

        {:ok, Map.put(context, :before, read_graph(context))}
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

      then_ "the graph no longer answers from the computation made before it", context do
        after_attempt = read_graph(context)

        refute after_attempt["computed_at"] == context.before["computed_at"],
               """
               The graph answered from the computation it made before the QA
               attempt was recorded.

               A QA attempt is a domain object we own — we wrote it, so the
               graph should have been told. If the answer is unchanged, the
               write published nothing and the graph is left to discover its own
               data by hashing a table.

               before: #{inspect(context.before["computed_at"])}
               after:  #{inspect(after_attempt["computed_at"])}
               """

        {:ok, context}
      end
    end
  end

end
