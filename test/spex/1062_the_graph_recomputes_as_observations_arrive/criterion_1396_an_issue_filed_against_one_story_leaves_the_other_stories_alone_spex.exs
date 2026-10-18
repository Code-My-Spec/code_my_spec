defmodule CodeMySpecSpex.Story1062.Criterion3476Spex do
  @moduledoc """
  Accepting a story issue introduces that issue's submission gate without
  reconsidering the requirements of another story. The graph endpoint exposes
  the new node and the unchanged timestamps on the unrelated story.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpec.ToolLibrary

  import CodeMySpecSpex.GraphReadHelpers
  import CodeMySpecSpex.StoryHelpers, only: [create_story: 2]
  import CodeMySpecSpex.TaskResponseHelpers, only: [extract_issue_id!: 1]

  alias Anubis.Server.Frame
  alias CodeMySpecSpex.Fixtures

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "An observation about one story's issues costs one story's requirements",
    criterion: 1396 do
    scenario "an issue is filed against one of two stories" do
      given_ "two stories in the graph", context do
        touched = create_story(context.scope, title: "The story it is about", description: "one")
        other = create_story(context.scope, title: "A story it is not about", description: "two")

        _warm = read_settled_graph(context)

        # Stamp rather than sleep. `checked_at` is second-resolution, so two
        # readings inside one second are indistinguishable and a recompute that
        # happened looks like one that did not.
        #
        # The baseline is read *after* the backdating: what this compares is
        # which requirements carry a time from after the observation.
        :ok = Fixtures.backdate_requirement_freshness(context.scope)

        before = read_settled_graph(context)

        {:ok,
         context
         |> Map.put(:touched_id, touched.id)
         |> Map.put(:touched_number, touched.number)
         |> Map.put(:other_id, other.id)
         |> Map.put(:before, before)}
      end

      when_ "an issue is filed against the first story and accepted", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        filed =
          ToolLibrary.run(
            "create_issue",
            %{
              title: "something is wrong on this story",
              description: "filed against one story and not the other",
              severity: "high",
              story_number: context.touched_number
            },
            Map.put(frame.assigns, :scope, frame.assigns[:current_scope])
          )

        assert match?({:ok, _}, filed), inspect(filed)

        accepted =
          ToolLibrary.run(
            "accept_issue",
            %{issue_id: extract_issue_id!(filed), story_number: context.touched_number},
            Map.put(frame.assigns, :scope, frame.assigns[:current_scope])
          )

        assert match?({:ok, _}, accepted), inspect(accepted)

        {:ok,
         context
         |> Map.put(:issue_id, extract_issue_id!(filed))
         |> Map.put(:after, read_settled_graph(context))}
      end

      then_ "the story issue gains an unfinished submission gate", context do
        assert satisfaction_of(context.after, "submitted", "issue", context.issue_id) == false

        refute Enum.any?(
                 context.before["nodes"],
                 &(&1["entity_type"] == "issue" and &1["entity_id"] == context.issue_id)
               )

        {:ok, context}
      end

      then_ "and the story it has nothing to do with is left as it was", context do
        before_other = freshness(context.before, context.other_id)
        after_other = freshness(context.after, context.other_id)

        assert before_other != [], "the unrelated story must have projected requirements"

        assert after_other == before_other,
               "accepting a finding on another story changed this story's requirement timestamps"

        {:ok, context}
      end
    end
  end

  # One story's requirements and when each was last worked out, as the endpoint
  # reports it. Sorted so two readings compare as sets rather than by whatever
  # order the graph returned them in.
  defp freshness(graph, story_id) do
    graph["nodes"]
    |> Enum.filter(&(&1["entity_type"] == "story" and &1["entity_id"] == story_id))
    |> Enum.map(&{&1["name"], &1["checked_at"]})
    |> Enum.sort()
  end
end
