defmodule CodeMySpecSpex.Story1062.Criterion3508Spex do
  @moduledoc """
  Story 1062 — The graph recomputes as observations arrive.
  Criterion 3508 — A writer that cannot say is read as the whole project.

  Rule: not naming a checkout fans out. It never narrows.

  ## The asymmetry this pins, and why it is not the same rule as 3518

  [[Criterion 3518]] bounds the other direction: an observation that *does* name
  a checkout must not settle the ones it did not name. Read alone, that rule has
  an obvious cheap reading — narrow everything, always — and the cheap reading
  is wrong in a way that is much harder to see than the fan-out it replaces.

  A story renamed, an issue filed, a criterion added: every checkout reads those
  and none of them is about any checkout. An agent renaming a story has an
  active checkout on its scope, so a system that inherits the vantage from the
  ambient scope narrows that rename to the agent's own worktree and leaves the
  other eight carrying the old title — silently, and for as long as nothing else
  happens to name those stories.

  So the two criteria are a pair and have to be read together. This one says the
  default when a writer has not said is the whole project, which is the
  conservative direction: fanning out too far costs work, and narrowing too far
  costs correctness.

  ## What it observes

  `last_drain`'s vantage count, from the same served endpoint the rest of this
  story reads, after an observation from a writer that names no checkout.

  A note on what a pass here means today. Nothing narrows yet — 3518 is red, and
  every observation settles every vantage — so this criterion currently passes
  for a reason that is not the one it is about. It is written now so that it is
  already in place when narrowing lands, because the moment that work starts
  this is the rule most likely to be broken by it and the one whose breakage is
  invisible from the checkout doing the writing.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.GraphReadHelpers
  import CodeMySpecSpex.SharedGivens
  import CodeMySpecSpex.StoryHelpers, only: [create_story: 2]
  import CodeMySpecSpex.WorkingCopyHelpers

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Issues.Tools.CreateIssue
  alias CodeMySpecSpex.Fixtures

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "An observation that names no checkout settles every checkout", criterion: 1420 do
    scenario "an issue is filed, which is about no checkout in particular" do
      given_(:synced_context_component)

      given_ "a second checkout of the same project", context do
        second_root = CodeMySpec.TempFile.owned_dir("test")
        {reply, _socket} = join_working_copy_socket(context, second_root, "the second checkout")
        second_id = reply["harness_id"] || reply[:working_copy_id]

        refute second_id == context.scope.active_working_copy_id,
               "two checkouts must be two copies; the server issued one id for both"

        {:ok,
         context
         |> Map.put(:first_id, context.scope.active_working_copy_id)
         |> Map.put(:second_id, second_id)}
      end

      given_ "both checkouts' requirements stored, and a story to file against", context do
        first = read_settled_graph(context, context.first_id)
        second = read_settled_graph(context, context.second_id)

        assert first["nodes"] != [], "the first checkout stores nothing to settle"
        assert second["nodes"] != [], "the second checkout stores nothing to settle"

        story =
          create_story(context.scope,
            title: "The story the issue is about",
            description: "so the observation has something to name"
          )

        :ok = Fixtures.settle_graph(context.scope)

        {:ok, context |> Map.put(:story_id, story.id) |> Map.put(:story_number, story.number)}
      end

      when_ "an issue is filed, by a writer whose change is about no checkout", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, filed, _frame} =
          CreateIssue.execute(
            %{
              title: "something is wrong on this story",
              description: "filed from one checkout and true of all of them",
              severity: "medium",
              story_number: context.story_number
            },
            frame
          )

        refute filed.isError, inspect(filed)

        :ok = Fixtures.settle_graph(context.scope)

        {:ok, Map.put(context, :drain, read_graph(context)["last_drain"])}
      end

      then_ "the drain says how many checkouts it settled", context do
        assert context.drain && is_integer(context.drain["vantages"]),
               """
               The drain did not report a vantage count, so whether this
               observation fanned out cannot be established at all.

               #{inspect(context.drain)}
               """

        {:ok, context}
      end

      then_ "and every checkout is settled rather than none", context do
        settled = context.drain["vantages"]

        assert settled >= 3,
               """
               An issue was filed and the drain settled #{settled} vantage(s).

               Three is what this project has: the two checkouts, and the `nil`
               row-space a reader with no checkout is answered from. An issue is
               about none of them — it is true of the project — so all three
               read it and all three have to be settled.

               Fewer means the observation was narrowed to somewhere. That is
               the failure that does not announce itself: the checkout that did
               the writing is correct afterwards, so whoever filed the issue
               sees exactly what they expect, and every other checkout goes on
               reporting the project clean.

               #{report(context.drain)}
               """

        {:ok, context}
      end
    end
  end

  defp report(drain) do
    "#{drain["kind"]} drain — #{drain["queries"]} queries, " <>
      "#{drain["rows_written"]} rows written, " <>
      "#{drain["observations"]} observation(s), " <>
      "#{drain["vantages"]} vantage(s)"
  end
end
