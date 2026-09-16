defmodule CodeMySpecSpex.Story1062.Criterion3429Spex do
  @moduledoc """
  Story 1062 — The graph recomputes as observations arrive.
  Criterion 3429 — A story arriving brings its requirements with it.

  Rule: requirements appear and disappear with the entities they belong to, not
  with the freshness of their answers.

  ## The lifecycle half, which the freshness machinery does not cover

  Everything else on this story is about *verdicts* moving: a fingerprint
  noticing an input changed, a pass recomputing what it touched. This is about
  rows existing at all, and it is a separate mechanism —
  `recompute_stale/3` reaches it through `appeared`, the set of entities the
  context has and the rows have never held.

  The two can fail independently. A graph whose freshness is perfect and whose
  lifecycle is broken serves an agent a project that is missing a story it can
  see in the backlog, and every freshness criterion passes while it does.

  ## Why it is stated as arrival rather than count

  A story released for development brings a fixed set of requirements — Three
  Amigos, specs, QA, the running copy — and asserting "some nodes appeared"
  would pass for a graph that produced one of them. The claim is that the
  story's own requirements are there, named, so the assertion is on the names.

  Paired with criterion 3430, which is the same rule going the other way. This
  one alone is satisfied by a graph that only ever adds.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.GraphReadHelpers
  import CodeMySpecSpex.StoryHelpers, only: [create_story: 2]

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "A story released for development arrives with its work" do
    scenario "a story is created on a project that has been read already" do
      given_ "a graph that has already been computed and served", context do
        # Read first, so the story arrives at a graph that exists rather than
        # at an empty one. A project whose rows have never been written takes
        # the whole-computation path, where every entity is new and "this story
        # brought its requirements" is indistinguishable from "the graph was
        # computed for the first time".
        _warm = read_settled_graph(context)

        {:ok, Map.put(context, :before, read_settled_graph(context))}
      end

      when_ "a story is released for development", context do
        story =
          create_story(context.scope,
            title: "A story that did not exist a moment ago",
            description: "released straight into a graph that had been served without it"
          )

        {:ok,
         context
         |> Map.put(:story_id, story.id)
         |> Map.put(:after, read_settled_graph(context))}
      end

      then_ "the graph held nothing for it before", context do
        assert requirements_for(context.before, context.story_id) == [],
               """
               The graph already carried requirements for a story that had not
               been created yet.

               The premise, not the claim — but a scenario where the rows were
               there all along asserts nothing about them arriving.

               before: #{inspect(requirements_for(context.before, context.story_id))}
               """

        {:ok, context}
      end

      then_ "and it carries the story's own requirements now", context do
        carried = requirements_for(context.after, context.story_id)

        for expected <- ~w(three_amigos_complete bdd_specs_exist qa_complete) do
          assert expected in carried,
                 """
                 A story was released for development and the graph does not
                 carry its #{expected} requirement.

                 Requirements appear with the entity they belong to. A story the
                 backlog shows and the graph does not is work an agent will
                 never be handed — and it is invisible from every freshness
                 measurement, because a row that was never written has no
                 staleness to report.

                 carried: #{inspect(carried)}
                 """
        end

        {:ok, context}
      end
    end
  end

  defp requirements_for(graph, story_id) do
    (graph["nodes"] || [])
    |> Enum.filter(
      &(&1["entity_type"] == "story" and to_string(&1["entity_id"]) == to_string(story_id))
    )
    |> Enum.map(& &1["name"])
    |> Enum.sort()
  end
end
