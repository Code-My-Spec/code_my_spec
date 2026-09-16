defmodule CodeMySpecSpex.Story1062.Criterion3496Spex do
  @moduledoc """
  Story 1062 — The graph recomputes as observations arrive.
  Criterion 3496 — A story released for development brings its requirements
  with it.

  Rule: requirements appear and disappear with the entities they belong to, not
  with the freshness of their answers.

  ## The population changing without the entity changing

  Criterion 3429 is a story arriving and 3430 a component going away. This is
  the case in between, and it is the one a system that *applies* observations
  gets wrong: the story existed before and exists after, and what changed is
  whether it is in the graph's population at all.

  `Preloader` filters stories on `ready_for_dev`, so a parked story produces no
  requirement rows and a released one produces every requirement it carries.
  Releasing is therefore creation as far as the rows are concerned, and parking
  is deletion — from an update to a row that was already there.

  ## Why that is a trap rather than a detail

  Settling a requirement is an `UPDATE`. It can change an answer and it cannot
  write a row that does not exist, so an observation that is *applied* rather
  than recomputed leaves a newly released story with nothing at all — and
  reports success, because every row it knew about was settled.

  Creation and deletion avoid this by being observations nothing applies, which
  sends them to a recompute. A readiness flip has to be in that set for the
  same reason, and it does not look like it belongs there: it is an ordinary
  field on an ordinary update.

  ## Why both directions

  Asserting only the release is satisfied by a graph that only ever adds — the
  same pairing 3429 and 3430 make. Parking a story that an agent is being
  handed work for is the direction that costs somebody an afternoon.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.GraphReadHelpers
  import CodeMySpecSpex.StoryHelpers, only: [create_story: 2]

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Stories.Tools.UpdateStory

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Releasing a story puts its work in the graph, and parking it takes it out" do
    scenario "a parked story is released, then parked again" do
      given_ "a story that exists but is not released for development", context do
        # Parked deliberately. `create_story/2` releases by default, because
        # most spex are describing work already in flight; this one is about
        # the gate itself.
        story =
          create_story(context.scope,
            title: "A story nobody has released yet",
            description: "shaped, and deliberately not started",
            ready_for_dev: false
          )

        _warm = read_settled_graph(context)

        {:ok,
         context
         |> Map.put(:story_id, story.id)
         |> Map.put(:parked, read_settled_graph(context))}
      end

      when_ "it is released, and then parked again", context do
        released = set_ready(context, true)
        reparked = set_ready(context, false)

        {:ok,
         context
         |> Map.put(:released, released)
         |> Map.put(:reparked, reparked)}
      end

      then_ "the graph held nothing for it while it was parked", context do
        assert requirements_for(context.parked, context.story_id) == [],
               """
               A story that has not been released for development is already
               carrying requirements.

               The premise, not the claim — but a scenario whose rows were
               there all along asserts nothing about them arriving. A parked
               story is work waiting to be shaped, and surfacing it as
               actionable is what the pace gate exists to prevent.

               parked: #{inspect(requirements_for(context.parked, context.story_id))}
               """

        {:ok, context}
      end

      then_ "and it carries its own requirements once released", context do
        carried = requirements_for(context.released, context.story_id)

        for expected <- ~w(three_amigos_complete bdd_specs_exist qa_complete) do
          assert expected in carried,
                 """
                 A story was released for development and the graph does not
                 carry its #{expected} requirement.

                 Releasing changes the population, not an answer. A system that
                 applies observations settles the rows it has and cannot write
                 one that was never there — so this story is released, visible
                 in the backlog, and invisible to every agent asking what to
                 work on. Nothing reports it, because every row that existed
                 was settled correctly.

                 carried: #{inspect(carried)}
                 """
        end

        {:ok, context}
      end

      then_ "and parking it takes them away again", context do
        assert requirements_for(context.reparked, context.story_id) == [],
               """
               A story was parked and the graph is still handing out its work.

               The direction that fails quietly: the rows are correct answers to
               a question nobody is asking any more. An agent is given a story
               somebody deliberately stopped, and the only evidence is a field
               on a row two screens away.

               still carried: #{inspect(requirements_for(context.reparked, context.story_id))}
               """

        {:ok, context}
      end
    end
  end

  defp set_ready(context, ready?) do
    frame = %Frame{assigns: %{current_scope: context.scope}}

    {:reply, updated, _frame} =
      UpdateStory.execute(
        %{story_id: to_string(context.story_id), ready_for_dev: ready?},
        frame
      )

    refute updated.isError, inspect(updated)

    read_settled_graph(context)
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
