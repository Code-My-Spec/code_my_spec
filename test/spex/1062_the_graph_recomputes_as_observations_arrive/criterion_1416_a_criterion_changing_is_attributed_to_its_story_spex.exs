defmodule CodeMySpecSpex.Story1062.Criterion3504Spex do
  @moduledoc """
  Story 1062 — The graph recomputes as observations arrive.
  Criterion 3504 — A criterion changing is attributed to its story.

  Rule: a verdict belongs to one checkout, and an observation says which
  checkouts it moves.

  ## Why this writer, specifically

  `AcceptanceCriteria` announces through `GraphInputs.story_entities/1`, which
  reaches into the broadcast message for a `story_id`. When that match fails it
  yields no entities, and a writer that names nothing is read as "could not say"
  — the whole project, at every checkout.

  That is not a hypothetical cost. On 2026-09-17 every criterion added to a
  story on this project triggered a full rebuild: one observation, ten
  checkouts, 246,500 rows written, sixteen seconds, repeating for as long as
  somebody kept editing the story. The immediate cause was elsewhere, but it
  was reached through this writer, and nothing asserted that a criterion change
  is about one story.

  ## What it reads, and what it does not

  Two stories: the one edited, and a bystander. The edited story's answers have
  to move — `bdd_specs_exist` goes unsatisfied the moment a criterion exists
  with no spex file covering it — and the bystander's have to be untouched.

  Both halves are needed. Asserting only that the bystander is untouched is
  satisfied by a graph that ignores criteria entirely; asserting only that the
  edited story moved is satisfied by a graph that recomputes everything.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.GraphReadHelpers
  import CodeMySpecSpex.SharedGivens
  import CodeMySpecSpex.StoryHelpers, only: [create_story: 2]

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Stories.Tools.AddCriterion

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "A criterion belongs to one story, and moves that story's answers", criterion: 1416 do
    scenario "A criterion changing is attributed to its story" do
      given_ :synced_context_component

      given_ "two stories, one about to be edited and one bystander", context do
        edited = create_story(context.scope, title: "Edited", description: "gains a criterion")
        bystander = create_story(context.scope, title: "Bystander", description: "gains nothing")

        {:ok,
         context
         |> Map.put(:edited_id, edited.id)
         |> Map.put(:bystander_id, bystander.id)}
      end

      given_ "what each story answers before the edit", context do
        # given: already true — `create_story/2` above made both stories, and
        # the reads below only record where they start. Without this baseline
        # the assertions after the edit cannot tell a change from a state that
        # was already there.
        graph = read_settled_graph(context)

        {:ok,
         context
         |> Map.put(:edited_before, answers(graph, context.edited_id))
         |> Map.put(:bystander_before, answers(graph, context.bystander_id))}
      end

      when_ "a criterion is added to the first story", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, reply, _frame} =
          AddCriterion.execute(
            %{
              story_id: to_string(context.edited_id),
              description: "a criterion that nothing covers yet"
            },
            frame
          )

        refute reply.isError, inspect(reply)

        graph = read_settled_graph(context)

        {:ok,
         context
         |> Map.put(:edited_after, answers(graph, context.edited_id))
         |> Map.put(:bystander_after, answers(graph, context.bystander_id))}
      end

      then_ "the story that gained it answers differently", context do
        refute context.edited_after == context.edited_before,
               """
               A criterion was added to this story and none of its answers
               moved. `bdd_specs_exist` should have gone unsatisfied — there is
               now a criterion with no spex covering it.

               Without this half, the assertion below is satisfied by a graph
               that ignores criteria entirely.

               before: #{inspect(context.edited_before)}
               after:  #{inspect(context.edited_after)}
               """

        {:ok, context}
      end

      then_ "and the story that did not answers exactly as it did", context do
        assert context.bystander_after == context.bystander_before,
               """
               A criterion added to another story changed this story's answers.

               Nothing was attributed here. If these verdicts moved, the writer
               named the project rather than the story it edited — which is the
               un-narrowed reading, and it costs a recompute of every entity at
               every checkout for an edit that touched one story.

               before: #{inspect(context.bystander_before)}
               after:  #{inspect(context.bystander_after)}
               """

        {:ok, context}
      end
    end
  end

  # Every answer a story's requirements give, verdict and details together: a
  # verdict that holds while its reason changes underneath is still an answer
  # that moved, and this criterion is about which story moved at all.
  defp answers(graph, story_id) do
    (graph["nodes"] || [])
    |> Enum.filter(
      &(&1["entity_type"] == "story" and to_string(&1["entity_id"]) == to_string(story_id))
    )
    |> Enum.map(&{&1["name"], &1["satisfied"], &1["details"]})
    |> Enum.sort()
  end
end
