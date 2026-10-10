defmodule CodeMySpecSpex.Story1062.Criterion3505Spex do
  @moduledoc """
  Story 1062 — The graph recomputes as observations arrive.
  Criterion 3505 — An issue filed reaches every checkout.

  Rule: a verdict belongs to one checkout, and an observation says which
  checkouts it moves.

  ## Why issues get their own scenario when 3503 already covers fan-out

  3503 proves a *story* change reaches every checkout. This is a different
  writer taking a different route to the same obligation, and the two have
  already diverged in production: on 2026-09-17 the live projection and the
  event path disagreed about `issues_resolved` on eight of nine checkouts, by
  counts that differed per checkout, for over two hours. Whatever that turns out
  to be, it was reached through `Issues` and not through `Stories`.

  So the claim is asserted where it broke rather than only where it was first
  written down.

  ## Filed *and* accepted, because filing alone is not this story's problem

  Story submission nodes include only issues that are accepted at or
  above the severity threshold. A freshly filed `:incoming` issue leaves every
  answer exactly where it was — correctly — so a scenario that stopped at
  filing would assert nothing and pass on a graph that ignores issues entirely.

  ## What would fail this

  Narrowing the issue to the checkout whose agent filed it. An issue is not a
  checkout's: every checkout reads the same issue rows, so every one of them has
  a story verdict to move. A projector that took its vantage from the writer's
  ambient scope would settle the filer's worktree and leave every other checkout
  telling agents the story is clear.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.GraphReadHelpers
  import CodeMySpecSpex.SharedGivens
  import CodeMySpecSpex.StoryHelpers, only: [create_story: 2]
  import CodeMySpecSpex.WorkingCopyHelpers

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Issues.Tools.{AcceptIssue, CreateIssue}

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "An issue belongs to the project, so every checkout hears about it", criterion: 1417 do
    scenario "An issue filed reaches every checkout" do
      given_(:synced_context_component)

      given_ "a story for the issue to be filed against", context do
        story =
          create_story(context.scope,
            title: "The story under complaint",
            description: "so the issue has somewhere to land"
          )

        {:ok, context |> Map.put(:story_id, story.id) |> Map.put(:story_number, story.number)}
      end

      given_ "a second checkout on the same project", context do
        second_root = CodeMySpec.TempFile.owned_dir("test")
        {reply, _socket} = join_working_copy_socket(context, second_root, "the second checkout")
        second_id = reply["harness_id"] || reply[:working_copy_id]

        refute second_id == context.scope.active_working_copy_id,
               "two checkouts must be two copies; the server issued one id for both"

        {:ok,
         context
         |> Map.put(:second_id, second_id)
         |> Map.put(:first_id, context.scope.active_working_copy_id)}
      end

      given_ "both checkouts show the story without issue submission nodes", context do
        # given: already true — the preceding givens created this story and joined both checkouts.
        for copy_id <- [context.first_id, context.second_id] do
          graph = read_settled_graph(context, copy_id)

          assert Enum.any?(
                   graph["nodes"],
                   &(&1["entity_type"] == "story" and
                       to_string(&1["entity_id"]) == to_string(context.story_id))
                 )

          refute Enum.any?(
                   graph["nodes"],
                   &(&1["entity_type"] == "issue" and &1["name"] == "submitted")
                 )
        end

        {:ok, context}
      end

      when_ "an issue is filed against it from one checkout and accepted", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, filed, _frame} =
          CreateIssue.execute(
            %{
              title: "something is wrong on this story",
              description: "filed from one checkout, true from all of them",
              severity: "high",
              story_number: context.story_number
            },
            frame
          )

        refute filed.isError, inspect(filed)

        {:reply, accepted, _frame} =
          AcceptIssue.execute(
            %{issue_id: issue_id(filed), story_number: context.story_number},
            frame
          )

        refute accepted.isError, inspect(accepted)

        {:ok,
         context
         |> Map.put(
           :first_after,
           submitted?(read_settled_graph(context, context.first_id), issue_id(filed))
         )
         |> Map.put(
           :second_after,
           submitted?(read_settled_graph(context, context.second_id), issue_id(filed))
         )}
      end

      then_ "the checkout it was filed from says the story is blocked", context do
        assert context.first_after == false,
               "an accepted high issue was filed from this checkout and it answers #{inspect(context.first_after)}"

        {:ok, context}
      end

      then_ "and so does the checkout that had nothing to do with it", context do
        assert context.second_after == false,
               """
               An issue was accepted against this story and this checkout still
               answers #{inspect(context.second_after)}.

               The issue was narrowed to the checkout whose agent filed it. Every
               checkout reads the same issue rows, so every one of them has a
               verdict to move — and this one is left telling an agent the story
               is clear while a high-severity issue sits accepted against it.
               """

        {:ok, context}
      end
    end
  end

  # The id out of the tool's own reply rather than by querying for it: the
  # criterion is about what happens once the issue exists, and reading it back
  # from the database would be asserting against the writer. Response content
  # carries string keys, so `Map.get(part, :text)` silently answers nil.
  defp issue_id(reply) do
    reply
    |> Map.get(:content, [])
    |> Enum.map_join(" ", &Map.get(&1, "text", ""))
    |> then(&Regex.run(~r/[0-9a-f]{8}-[0-9a-f-]{27,}/, &1))
    |> List.first()
  end

  # Missing projection is distinct from an unsatisfied submission.
  defp submitted?(graph, issue_id) do
    (graph["nodes"] || [])
    |> Enum.find(
      &(&1["entity_type"] == "issue" and &1["entity_id"] == issue_id and &1["name"] == "submitted")
    )
    |> verdict_of()
  end

  defp verdict_of(nil), do: nil
  defp verdict_of(node), do: node["satisfied"]
end
