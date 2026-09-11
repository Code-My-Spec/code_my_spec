defmodule CodeMySpecSpex.Story1063.Criterion3344Spex do
  @moduledoc """
  Story 1063 — A cached graph is never served after its inputs have moved.
  Criterion 3344 — A deploy being recorded moves the graph.

  Rule: a domain object we own publishes an event when it changes.

  The last of the ten inputs, and the one furthest from the others in origin: a
  deploy is recorded by devops machinery rather than by an agent working a
  story, so it is the input most likely to be forgotten when somebody
  enumerates "the things an agent does".

  It still gates work. A story's chain runs past its deploy, so a deploy
  landing can make the next requirement actionable — and a graph that has not
  heard about it goes on reporting the story as blocked on something that has
  already happened.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.GraphReadHelpers

  import CodeMySpecSpex.StoryHelpers, only: [create_story: 2]

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Recording a deploy moves the graph" do
    scenario "a deploy is recorded for a story" do
      given_ "a released story and a graph that has been served", context do
        story = create_story(context.scope, title: "Shipped", description: "a story to deploy")

        _cold = read_graph(context)

        {:ok,
         context
         |> Map.put(:new_story, story)
         |> Map.put(:before, read_graph(context))}
      end

      when_ "a deploy is recorded for that story", context do
        # Through the bridge: the boundary refuses CodeMySpecSpex reaching into
        # CodeMySpec directly, and the environment is a string rather than an
        # atom — an atom fails the cast inside the query rather than at the call.
        _deploy = CodeMySpecSpex.Fixtures.record_deploy(context.scope, context.new_story.id, "uat")

        {:ok, context}
      end

      then_ "the graph no longer answers from the computation made before it", context do
        after_deploy = read_graph(context)

        refute after_deploy["computed_at"] == context.before["computed_at"],
               """
               A deploy was recorded and the graph went on answering from the
               computation it made before.

               A deploy is recorded by devops machinery rather than by an agent
               working a story, which makes it the input most easily left off a
               list of "things an agent does" — and a story's chain still runs
               past it.

               before: #{inspect(context.before["computed_at"])}
               after:  #{inspect(after_deploy["computed_at"])}
               """

        {:ok, context}
      end
    end
  end

end
