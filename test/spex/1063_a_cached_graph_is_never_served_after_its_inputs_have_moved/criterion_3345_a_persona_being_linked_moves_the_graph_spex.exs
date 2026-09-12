defmodule CodeMySpecSpex.Story1063.Criterion3345Spex do
  @moduledoc """
  Story 1063 — A cached graph is never served after its inputs have moved.
  Criterion 3345 — A persona being linked moves the graph.

  Rule: a domain object we own publishes an event when it changes.

  Personas gate the Three Amigos chain — a story with none linked cannot take a
  rule at all, the tool refuses it — so linking one is the moment a story's
  whole specification chain becomes reachable.

  It is also the input whose linkage is least like the others. Stories and
  issues carry a `project_id`; criteria carry a `story_id`; personas hang off a
  join table and belong to neither directly. `Preloader` has a separate query
  for exactly that reason, and an input needing its own query shape is the one a
  hand-maintained list of inputs quietly omits.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.GraphReadHelpers

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Personas.Tools.LinkPersonaToStory
  alias CodeMySpecSpex.ProjectStateFixtures

  import CodeMySpecSpex.StoryHelpers, only: [create_story: 2]

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Linking a persona moves the graph" do
    scenario "a persona is linked to a story" do
      given_ "a story with no persona, a persona that exists, and a served graph",
             context do
        story = create_story(context.scope, title: "Unpersonaed", description: "no persona yet")
        context = ProjectStateFixtures.apply_persona(context)

        _cold = read_graph(context)

        {:ok,
         context
         |> Map.put(:new_story, story)
         |> Map.put(:before, read_graph(context))}
      end

      when_ "the persona is linked to the story", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, response, _frame} =
          LinkPersonaToStory.execute(
            %{persona_id: context.persona_id, story_id: context.new_story.id},
            frame
          )

        refute response.isError,
               "the link must really be made for this to mean anything:\n" <> inspect(response)

        {:ok, context}
      end

      then_ "the graph no longer answers from the computation made before it", context do
        after_link = read_graph(context)

        refute after_link["computed_at"] == context.before["computed_at"],
               """
               A persona was linked and the graph went on answering from the
               computation it made before.

               Personas hang off a join table rather than carrying a project_id
               or a story_id, so finding them needs its own query. An input that
               needs its own query shape is the one a hand-maintained list of
               inputs omits.

               before: #{inspect(context.before["computed_at"])}
               after:  #{inspect(after_link["computed_at"])}
               """

        {:ok, context}
      end
    end
  end

end
