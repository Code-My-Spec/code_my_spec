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
  # `deploy` is filtered out of the story graph on the default `devops: :off`
  # (see `RequirementDefinitionData`), so without this the requirement under
  # test does not exist and the scenario asserts on a node that was never
  # there.
  setup :devops_uat_only

  spex "Recording a deploy moves the graph" do
    scenario "a deploy is recorded for a story" do
      given_ "a released story and a graph that has been served", context do
        story = create_story(context.scope, title: "Shipped", description: "a story to deploy")

        before = read_settled_graph(context)

        assert satisfaction_of(before, "deploy", :story, story.id) == false,
               """
               The premise did not hold: this story's `deploy` is not open
               before the deploy is recorded, so recording one has nowhere to
               show up.

               deploy: #{inspect(satisfaction_of(before, "deploy", :story, story.id))}
               """

        {:ok,
         context
         |> Map.put(:new_story, story)
         |> Map.put(:before, before)}
      end

      when_ "a deploy is recorded for that story", context do
        # Through the bridge: the boundary refuses CodeMySpecSpex reaching into
        # CodeMySpec directly, and the environment is a string rather than an
        # atom — an atom fails the cast inside the query rather than at the call.
        _deploy = CodeMySpecSpex.Fixtures.record_deploy(context.scope, context.new_story.id, "uat")

        {:ok, context}
      end

      then_ "the graph says that story has been deployed", context do
        after_deploy = read_graph(context)

        assert satisfaction_of(after_deploy, "deploy", :story, context.new_story.id) == true,
               """
               A deploy was recorded and the graph still says the story has not
               been deployed.

               A deploy is recorded by devops machinery rather than by an agent
               working a story, which makes it the input most easily left off a
               list of "things an agent does" — and a story's chain still runs
               past it.

               The claim is the verdict, not a clock: a pass that ran and
               applied nothing moves `computed_at` exactly as far as one that
               worked, and `checked_at` is second-resolution besides.

               deploy before: #{inspect(satisfaction_of(context.before, "deploy", :story, context.new_story.id))}
               deploy after:  #{inspect(satisfaction_of(after_deploy, "deploy", :story, context.new_story.id))}
               """

        {:ok, context}
      end
    end
  end

end
