defmodule CodeMySpecSpex.Story1063.Criterion3237Spex do
  @moduledoc """
  Story 1063 — A cached graph is never served after its inputs have moved.
  Criterion 3237 — One story's attempt moves that story and leaves the others.

  Rule: a domain event updates only the part of the graph it affects.

  The reason trusting events is affordable. If every event recomputed the whole
  project — measured at about 4.4 seconds — then being wrong about whether
  anything really changed would be expensive, and the fingerprint would be
  earning its keep. Updating only what the event bears on makes a redundant
  event cost a couple of requirements, which is what lets the fingerprint go
  for owned objects entirely.

  Observed by comparing the two stories' nodes in the cached graph across the
  event: the one the attempt was recorded against should differ, and the other
  should not.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.GraphReadHelpers

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Qa.Tools.SubmitQaResult

  setup :register_log_in_setup_account
  setup :setup_active_project
  setup :setup_qa_story_task

  spex "An attempt on one story leaves the other story alone" do
    scenario "two stories, one attempt" do
      given_ "a second story with its own QA task, and a graph that has been served",
             context do
        {other_story, other_task_id, _session} =
          CodeMySpecSpex.Fixtures.qa_story_task_fixture(context.scope,
            title: "The other story"
          )

        _cold = read_graph(context)

        {:ok,
         context
         |> Map.put(:other_story, other_story)
         |> Map.put(:other_task_id, other_task_id)
         |> Map.put(:before, read_graph(context))}
      end

      when_ "a QA attempt is recorded against the first story only", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, response, _frame} =
          SubmitQaResult.execute(
            %{
              task_id: context.task_id,
              status: "pass",
              scenarios: [%{name: "smoke", status: "pass", observation: "ok"}],
              issue_ids: []
            },
            frame
          )

        refute response.isError,
               "the attempt must really be recorded for this scenario to mean anything:\n" <>
                 inspect(response)

        {:ok, context}
      end

      then_ "the first story's requirements moved and the second story's did not", context do
        after_attempt = read_graph(context)

        assert nodes_for(after_attempt, context.story.id) != nodes_for(context.before, context.story.id),
               """
               The story the attempt was recorded against did not change.

               If its own requirements do not move, the attempt reached nothing
               and the rest of this criterion is vacuous.
               """

        assert nodes_for(after_attempt, context.other_story.id) ==
                 nodes_for(context.before, context.other_story.id),
               """
               A QA attempt on one story changed another story's requirements.

               An event carries the object it concerns, so the update should
               touch what that object bears on and leave the rest of the
               project's graph as it stands. A whole-project recompute per
               event is the cost that makes trusting events look expensive.
               """

        {:ok, context}
      end
    end
  end

  defp nodes_for(graph, story_id) do
    graph["nodes"]
    |> Enum.filter(&(&1["entity_type"] == "story" and &1["entity_id"] == story_id))
    |> Enum.sort_by(& &1["name"])
  end

end
