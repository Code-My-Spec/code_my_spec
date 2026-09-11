defmodule CodeMySpecSpex.Story1063.Criterion3340Spex do
  @moduledoc """
  Story 1063 — A cached graph is never served after its inputs have moved.
  Criterion 3340 — A story being released moves the graph.

  Rule: a domain object we own publishes an event when it changes.

  Stories are the input that creates work rather than satisfying it. A story
  that is not released produces no requirements at all — the graph treats it as
  absent — so releasing one is the moment a whole chain of requirements comes
  into existence.

  That makes it the input with the largest effect and the one most visibly
  wrong if missed: an agent asking what to do next would be told "nothing"
  while a freshly released story sat waiting.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.GraphReadHelpers

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Stories.Tools.UpdateStory

  # `Fixtures.story_fixture/2` is deliberately private: it was a plain wrapper
  # around `Stories.create_story/2` with no MCP layer to it, and spex create a
  # story through the surface one is actually created through.
  import CodeMySpecSpex.StoryHelpers, only: [create_story: 2]

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Releasing a story moves the graph" do
    scenario "a story is released for development" do
      given_ "a story not yet released, and a graph that has been served", context do
        # Keyword list, not a map — it goes through the CreateStory MCP tool.
        # `ready_for_dev: false` leaves it parked: a story produces no
        # requirements until released, so releasing it is the change under test
        # rather than setup.
        story =
          create_story(context.scope,
            title: "Not yet released",
            description: "waiting to be released",
            ready_for_dev: false
          )

        _cold = read_graph(context)

        {:ok,
         context
         |> Map.put(:new_story, story)
         |> Map.put(:before, read_graph(context))}
      end

      when_ "the story is released for development", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, response, _frame} =
          UpdateStory.execute(
            %{story_id: to_string(context.new_story.id), ready_for_dev: true},
            frame
          )

        refute response.isError,
               "the story must really be released for this to mean anything:\n" <>
                 inspect(response)

        {:ok, context}
      end

      then_ "the graph no longer answers from the computation made before it", context do
        after_release = read_graph(context)

        refute after_release["computed_at"] == context.before["computed_at"],
               """
               A story was released and the graph went on answering from the
               computation it made before.

               A released story brings a whole chain of requirements into
               existence. If the graph does not hear about it, an agent asking
               what to do next is told there is nothing while the story waits.

               before: #{inspect(context.before["computed_at"])}
               after:  #{inspect(after_release["computed_at"])}
               """

        {:ok, context}
      end
    end
  end

end
