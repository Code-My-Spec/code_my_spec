defmodule CodeMySpecSpex.Story1062.Criterion3421Spex do
  @moduledoc """
  Story 1062 — The graph recomputes as observations arrive.
  Criterion 3421 — One story's observation leaves another story's answer alone.

  Rule: a requirement's freshness is decided by the sources it was computed
  from, not by the project's.

  ## Not the same claim as 3424 or 3476, and the difference is the point

  Both of those assert **cost**: an observation must not recompute a story it
  has nothing to do with, measured on `checked_at`. This asserts **the answer**.
  They fail in different directions and a system can pass either while failing
  the other.

  A graph that recomputes every story on every observation is wasteful and
  correct — 3424 and 3476 catch it, this one does not. A graph that recomputes
  only what it should but lets a project-wide fact into a per-story verdict is
  cheap and *wrong*, and only this one catches it. The second is the worse
  failure: an agent is told a story is blocked by something that was never
  about it, and nothing in the cost measurements would show anything unusual.

  ## Why issues are the observation

  Because this boundary is drawn by hand and can be redrawn by accident.
  `IssuesChecker.story_resolved?/2` counts only what QA attributed to the story
  it is asked about, and says so — "an issue with no `story_id` is the project
  queue's problem, not this story's". The project-wide readers are separate
  nodes: `issues_triaged` and `issues_resolved` hang off the project, and
  `recompute_stale/3` rebuilds project nodes unconditionally on every pass.

  So one issue filed against one story has exactly one story's answer to move.
  Widening `story_issues_resolved` to the project queue — which is the shape it
  had before criterion 3476, and a one-line change away at any time — turns
  every open issue anywhere into every story's problem, and the graph would go
  on costing exactly what it costs now while saying it.

  ## What it reads

  The verdict and the reason, per requirement, for each story. Not
  `checked_at`: a row recomputed to the identical answer satisfies this
  criterion and violates 3424, and conflating them would make both untestable.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.GraphReadHelpers
  import CodeMySpecSpex.StoryHelpers, only: [create_story: 2]

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Issues.Tools.{AcceptIssue, CreateIssue}

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "An issue against one story is not another story's problem" do
    scenario "an issue is filed against one of two stories" do
      given_ "two stories in the graph, and the answers they start with", context do
        touched = create_story(context.scope, title: "The story it is about", description: "one")
        other = create_story(context.scope, title: "A story it is not about", description: "two")

        # Read twice before taking the baseline. `GraphWatcher.settle/1` answers
        # `:ok` when it holds no timer, which it cannot tell from "the
        # announcement creating these stories has not arrived yet" — so the
        # first read can return before the pass it should have waited for.
        _warm = read_settled_graph(context)

        {:ok,
         context
         |> Map.put(:touched_id, touched.id)
         |> Map.put(:other_id, other.id)
         |> Map.put(:before, read_settled_graph(context))}
      end

      when_ "an issue is filed against the first story and triaged in", context do
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

        # Filed *and* accepted, because filing alone is deliberately not this
        # story's problem yet. `IssuesChecker.story_resolved?/2` counts
        # `:accepted` issues only, so a fresh `:incoming` one leaves every
        # answer where it was — correctly, and it is what the first run of this
        # measured: the touched story still reported "No unresolved medium+
        # issues on this story" with the issue sitting in the queue untriaged.
        {:reply, accepted, _frame} =
          AcceptIssue.execute(%{issue_id: issue_id(filed), story_id: context.touched_id}, frame)

        refute accepted.isError, inspect(accepted)

        {:ok, Map.put(context, :after, read_settled_graph(context))}
      end

      then_ "the story it was filed against answers differently", context do
        refute answers(context.after, context.touched_id) ==
                 answers(context.before, context.touched_id),
               """
               An issue was filed against this story and its answers did not
               change.

               Without this half the criterion below is satisfied by a graph
               that ignores issues entirely — every story's answer would be left
               alone, including the one the issue is about.

               before: #{inspect(answers(context.before, context.touched_id))}
               after:  #{inspect(answers(context.after, context.touched_id))}
               """

        {:ok, context}
      end

      then_ "and the other story answers exactly as it did", context do
        assert answers(context.after, context.other_id) ==
                 answers(context.before, context.other_id),
               """
               An issue filed against one story changed another story's answer.

               Nothing was attributed to this story. If its requirements now
               report a problem, the boundary `IssuesChecker.story_resolved?/2`
               draws has been widened to the project queue, and every open issue
               anywhere is now every story's problem — an agent told a story is
               blocked by something that was never about it.

               before: #{inspect(answers(context.before, context.other_id))}
               after:  #{inspect(answers(context.after, context.other_id))}
               """

        {:ok, context}
      end
    end
  end

  # The id out of the tool's own reply, rather than by querying for it — the
  # criterion is about what happens after the issue exists, and reading it back
  # from the database would be asserting against the writer.
  #
  # `Anubis.Server.Response` carries its content as maps with **string** keys,
  # so `Map.get(part, :text)` silently answers `nil` for every part and the id
  # is never found.
  defp issue_id(reply) do
    reply
    |> Map.get(:content, [])
    |> Enum.map_join(" ", &Map.get(&1, "text", ""))
    |> then(&Regex.run(~r/[0-9a-f]{8}-[0-9a-f-]{27,}/, &1))
    |> List.first()
  end

  # The answers a story's requirements give, which is what an agent is told.
  # Verdict and reason together: `three_amigos_complete` is false whether a
  # story has no scenarios at all or is one seal away, so a verdict alone would
  # miss a reason changing under it.
  defp answers(graph, story_id) do
    (graph["nodes"] || [])
    |> Enum.filter(
      &(&1["entity_type"] == "story" and to_string(&1["entity_id"]) == to_string(story_id))
    )
    |> Enum.map(&{&1["name"], &1["satisfied"], &1["details"]})
    |> Enum.sort()
  end
end
