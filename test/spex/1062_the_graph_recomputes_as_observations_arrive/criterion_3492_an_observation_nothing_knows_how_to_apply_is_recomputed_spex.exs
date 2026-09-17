defmodule CodeMySpecSpex.Story1062.Criterion3492Spex do
  @moduledoc """
  Story 1062 — The graph recomputes as observations arrive.
  Criterion 3492 — An observation nothing knows how to apply is recomputed
  rather than dropped.

  Rule: an observation settles every requirement it moves, or it is recomputed
  instead.

  ## The half of the rule that is easy to lose

  Handlers are added one event kind at a time, and the projection has to stay
  correct the whole way through — slower where a handler is missing, never
  wrong. The failure this rules out is an event arriving, finding no handler,
  and being consumed anyway: the mark is gone, nothing recomputed, and the
  entity carries yesterday's answer with nothing left to correct it.

  That is not theoretical. The drain deliberately discards an event's fallback
  marks once a handler claims the kind, which is right only because the handler
  settles everything the event moved. The same discard with no handler at all
  would be silent loss.

  ## Why story creation is the observation

  `story_created` has no handler and is meant not to have one: handlers settle
  rows and cannot write rows that do not exist yet, so an entity arriving must
  fall back to a recompute. It is the cheapest honest way to drive the
  unhandled path through a real surface — `create_story` is what a PM or an
  agent actually calls.

  ## What it asserts, beyond 3429

  3429 says a released story's requirements *exist*. This says they were
  *answered*: every one carries a verdict and the checker's own words for it.
  A fallback that created rows and left them blank would satisfy 3429 and fail
  here, and blank rows are exactly what a dropped observation looks like from
  outside — present, plausible, and never computed.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.GraphReadHelpers
  import CodeMySpecSpex.SharedGivens
  import CodeMySpecSpex.StoryHelpers, only: [create_story: 2]

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "An event with no handler still leaves the graph answered" do
    scenario "An observation nothing knows how to apply is recomputed rather than dropped" do
      given_ :synced_context_component

      given_ "a graph that has already been computed", context do
        graph = read_settled_graph(context)

        assert graph["nodes"] != [],
               "nothing is stored yet, so a story appearing cannot be told from a first computation"

        {:ok, context}
      end

      when_ "a story is created, which no handler knows how to apply", context do
        story =
          create_story(context.scope,
            title: "Arrived",
            description: "by a route the graph has no handler for"
          )

        {:ok,
         context
         |> Map.put(:story_id, story.id)
         |> Map.put(:graph, read_settled_graph(context))}
      end

      then_ "the story it named carries requirements", context do
        assert answers(context.graph, context.story_id) != [],
               """
               The story was created and the graph holds no requirements for it.

               The observation named this entity and nothing recomputed it — the
               event had no handler and was dropped rather than fallen back on.
               """

        {:ok, context}
      end

      then_ "and every one of them has been answered", context do
        unanswered =
          context.graph
          |> answers(context.story_id)
          |> Enum.filter(fn {_name, satisfied, details} ->
            is_nil(satisfied) or is_nil(details) or details == %{}
          end)

        assert unanswered == [],
               """
               These requirements exist for the new story but carry no answer:

               #{inspect(unanswered)}

               Rows that exist and were never computed are what a dropped
               observation looks like from outside — present and plausible. The
               recompute the fallback owes has to have actually run.
               """

        {:ok, context}
      end
    end
  end

  defp answers(graph, story_id) do
    (graph["nodes"] || [])
    |> Enum.filter(
      &(&1["entity_type"] == "story" and to_string(&1["entity_id"]) == to_string(story_id))
    )
    |> Enum.map(&{&1["name"], &1["satisfied"], &1["details"]})
    |> Enum.sort()
  end
end
