defmodule CodeMySpecSpex.Story1062.Criterion3501Spex do
  @moduledoc """
  Story 1062 — The graph recomputes as observations arrive.
  Criterion 3501 — A change in the main checkout also settles the answers kept
  for no checkout.

  Rule: a verdict belongs to one checkout, and an observation says which
  checkouts it moves.

  ## The vantage nobody names

  Most readers name no checkout. A browser has none to name; so does anything
  asking about the project rather than about a tree. Those readers are answered
  from rows kept under no working copy at all, and those rows are computed from
  *some* checkout's files — the project's main one, because a verdict like "this
  component has an implementation" is only ever true from somewhere.

  That makes the unscoped rows a checkout's answers wearing the project's name,
  and it puts them in an odd position: they are moved by one checkout's files
  and by no other's. Both halves have gone wrong in the same week.

  ## Why the second half is asserted, and asserted first

  A change arriving in another worktree must leave these rows alone, and that is
  the half that fails quietly. Two ways it has:

    * The rows were computed from whichever checkout the reader happened to
      have, so a worktree with the file read as the project having it.
    * A sweep's default names no entity — it is "every row this requirement's
      exceptions did not name" — and `working_copy_id` was the only thing
      narrowing it. `nil` is the vantage every project shares, so one project's
      drain answered every project's unscoped rows.

  Taken alone, though, "left alone" is satisfied by a graph that ignores file
  syncs entirely. So the main checkout's change has to be shown moving these
  rows afterwards, and only then is the other checkout's stillness evidence of
  anything.

  ## Why main is a checkout that joined rather than the one that synced

  `:synced_context_component` syncs through the `/files` page, which files what
  it finds under the most recently active copy and hands back no channel. A
  checkout that joined holds a socket, which is how a criterion makes files
  arrive in a *named* tree rather than in whichever one was last seen.

  So main here is a checkout that joined and was then designated through the
  control that designates one, and the baselines are taken after both joins: a
  copy appearing is itself a project-wide observation, and reading before them
  would attribute their effects to the file syncs under test.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.GraphReadHelpers
  import CodeMySpecSpex.MainAgentHelpers, only: [designate_main_copy: 2]
  import CodeMySpecSpex.SharedGivens
  import CodeMySpecSpex.WorkingCopyHelpers

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "The project's own answers follow its main checkout and nobody else's", criterion: 1414 do
    scenario "A change in the main checkout also settles the answers kept for no checkout" do
      given_ :synced_context_component

      given_ "a checkout that is the project's main one", context do
        {:ok, root} = Briefly.create(directory: true)
        {reply, socket} = join_working_copy_socket(context, root, "the main checkout")
        main_id = reply["harness_id"] || reply[:working_copy_id]

        :ok = designate_main_copy(context, main_id)

        {:ok, context |> Map.put(:main_id, main_id) |> Map.put(:main_socket, socket)}
      end

      given_ "and another checkout on the same project", context do
        {:ok, root} = Briefly.create(directory: true)
        {reply, socket} = join_working_copy_socket(context, root, "the other checkout")
        other_id = reply["harness_id"] || reply[:working_copy_id]

        refute other_id == context.main_id,
               "two checkouts must be two copies; the server issued one id for both"

        {:ok, context |> Map.put(:other_id, other_id) |> Map.put(:other_socket, socket)}
      end

      given_ "what a reader naming no checkout is answered before anything is synced",
             context do
        {:ok, Map.put(context, :before, verdicts(read_settled_graph(context)))}
      end

      when_ "the file arrives in the other checkout, and then in the main one", context do
        report(context.other_socket)
        after_other = verdicts(read_settled_graph(context))

        report(context.main_socket)
        after_main = verdicts(read_settled_graph(context))

        {:ok,
         context
         |> Map.put(:after_other, after_other)
         |> Map.put(:after_main, after_main)}
      end

      then_ "the other checkout's file left those answers exactly as they were", context do
        assert context.after_other == context.before,
               """
               A file that arrived in another worktree moved the answers kept for
               no checkout in particular.

               Those rows are the project's answer — what a browser, and anything
               asking about the project rather than about a tree, is served. They
               follow the main checkout's files and no other's, so a file landing
               somewhere else has to leave them alone. It did not, which means a
               reader with no checkout is being served some checkout's answers as
               though they were the project's.

               before: #{inspect(context.before)}
               after:  #{inspect(context.after_other)}
               """

        {:ok, context}
      end

      then_ "and the same file arriving in the main checkout settled them", context do
        refute context.after_main == context.after_other,
               """
               The file then arrived in the main checkout and the answers kept for
               no checkout did not move.

               Those rows are computed from main's files, so this is the change
               they exist to follow. Unmoved, they are frozen at whatever main
               looked like when something last happened to settle them — and the
               criterion above passes for a graph that ignores file syncs
               entirely, which is why this one is here.

               after the other checkout: #{inspect(context.after_other)}
               after the main checkout:  #{inspect(context.after_main)}
               """

        {:ok, context}
      end
    end
  end

  # The implementation file `:synced_context_component`'s component expects.
  # One path, reported the way a harness reports what it found.
  defp report(socket) do
    ref =
      Phoenix.ChannelTest.push(socket, "observations", %{
        "observations" => [
          %{
            "path" => "lib/example_context.ex",
            "role" => "implementation",
            "fingerprint" => "the same file in a second tree",
            "mtime" => "2026-09-17T00:00:00.000000Z"
          }
        ]
      })

    Phoenix.ChannelTest.assert_reply(ref, :ok, _summary, 2000)
  end

  # Every verdict in a graph read, as a sorted list, because the criterion is
  # about which checkout's files these rows follow rather than about any one
  # requirement. Details ride along: a verdict that stays true while its reason
  # changes underneath is still an answer that moved.
  defp verdicts(graph) do
    (graph["nodes"] || [])
    |> Enum.map(
      &{&1["entity_type"], to_string(&1["entity_id"]), &1["name"], &1["satisfied"],
       &1["details"]}
    )
    |> Enum.sort()
  end
end
