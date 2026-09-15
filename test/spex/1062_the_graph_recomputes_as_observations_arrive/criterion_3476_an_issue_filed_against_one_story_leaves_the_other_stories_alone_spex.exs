defmodule CodeMySpecSpex.Story1062.Criterion3476Spex do
  @moduledoc """
  Story 1062 — The graph recomputes as observations arrive.
  Criterion 3476 — An issue filed against one story leaves the other stories alone.

  Rule: an observation costs work in proportion to what it changed, not to the
  size of the project.

  ## What this is for

  Criterion 3424 bounds the cost for an observation about a story's own
  content. This is the same claim for the input that is still shared:
  `Preloader.delegated_inputs/2` collects `issues` as one project-wide list of
  stamps, and `Freshness.story/2` hashes that list into every story's
  fingerprint. So one issue moves every story's fingerprint and every story's
  requirements are recomputed.

  `Freshness` says so itself, and accepted the trade on the grounds that issues
  are "filed and resolved by hand, a handful a day". The module's own later
  note records that this premise is measurably false — issues were touched at
  14:12, 14:21, 14:24 and 14:34 in one half hour, each by an agent rather than
  a person.

  Measured on dev, 2026-09-14: one `[Issues] announcing a graph change`
  observation recomputed **973 of 2086 requirements, 137 of 137 stories**. Every
  story in the project, to answer a question about one.

  ## Why the grain is available

  `IssuesChecker` already draws the line this needs. `triaged?/2` and
  `resolved?/2` answer for the **project** and are project nodes, which
  `recompute_stale/3` rebuilds unconditionally every pass — so they do not read
  a story's fingerprint at all. The only story-level reader is
  `story_resolved?/2`, and its own docstring says what it reads: "Only issues QA
  attributed to the story count. An issue with no `story_id` is the project
  queue's problem, not this story's."

  So the project-wide stamp in a story's fingerprint buys nothing. It is not a
  trade between correctness and cost; it is cost with no correctness behind it.

  ## What it observes

  `checked_at` per requirement, read over the graph endpoint — 3424's technique,
  for the same reason: one `computed_at` for the whole graph moves whether or
  not the work was necessary, so the reading that separates "recomputed what it
  touched" from "recomputed everything" does not exist at graph grain.

  ## Why the issue is only attributed, not accepted

  `story_resolved?/2` counts **accepted** issues at or above the threshold, and
  a filed issue is `incoming`. So this observation deliberately does not change
  any story's *answer* — it changes one story's *inputs*. That is the sharper
  version of the claim: the story it was filed against is reconsidered because
  its inputs moved, and no other story is, because theirs did not.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.GraphReadHelpers
  import CodeMySpecSpex.StoryHelpers, only: [create_story: 2]

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Issues.Tools.CreateIssue
  alias CodeMySpecSpex.Fixtures

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "An observation about one story's issues costs one story's requirements" do
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
         |> Map.put(:other_id, other.id)
         |> Map.put(:before, before)}
      end

      when_ "an issue is filed and attributed to the first story", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, filed, _frame} =
          CreateIssue.execute(
            %{
              title: "something is wrong on this story",
              description: "filed against one story and not the other",
              severity: "medium",
              story_id: context.touched_id
            },
            frame
          )

        refute filed.isError, inspect(filed)

        {:ok, Map.put(context, :after, read_settled_graph(context))}
      end

      then_ "the story it was filed against is reconsidered", context do
        refute freshness(context.after, context.touched_id) ==
                 freshness(context.before, context.touched_id),
               """
               An issue was attributed to this story and its requirements were
               not reconsidered.

               `story_issues_resolved` reads the issues attributed to this
               story. If filing one does not move its requirements, the graph
               goes on answering from before the issue existed, and nothing
               will change its mind until some unrelated input moves.

               before: #{inspect(freshness(context.before, context.touched_id))}
               after:  #{inspect(freshness(context.after, context.touched_id))}
               """

        {:ok, context}
      end

      then_ "and the story it has nothing to do with is left as it was", context do
        before_other = freshness(context.before, context.other_id)
        after_other = freshness(context.after, context.other_id)

        assert after_other == before_other,
               """
               An issue filed against one story recomputed another story's
               requirements too.

               Nothing about that story moved. `delegated_inputs/2` collects
               `issues` as one project-wide list of stamps and `Freshness.story/2`
               hashes it into every story's fingerprint, so one issue restales
               every story in the project.

               The grain is already there and unused: the only story-level
               reader is `IssuesChecker.story_resolved?/2`, which counts only
               the issues attributed to that story — "an issue with no
               `story_id` is the project queue's problem, not this story's". The
               project-level checks are project nodes and are rebuilt every pass
               regardless.

               Measured on dev: one issue, 973 of 2086 requirements, 137 of 137
               stories.

               before: #{inspect(before_other)}
               after:  #{inspect(after_other)}
               """

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
