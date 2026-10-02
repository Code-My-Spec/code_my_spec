defmodule CodeMySpecSpex.Story1062.Criterion3506Spex do
  @moduledoc """
  Story 1062 — The graph recomputes as observations arrive.
  Criterion 3506 — Files syncing is about the checkout they synced from.

  Rule: a writer says whether what it moved is about one checkout or about the
  whole project.

  ## The failure this exists to catch

  A verdict is a statement about a checkout — `Preloader.load/1` scopes its file
  query to one, so "this component has an implementation" is only ever true
  *from somewhere*. Files arriving in one worktree therefore move that
  checkout's answers and no one else's.

  Nothing enforced that. The projector settled whichever checkout happened to
  start it, which failed in both directions at once: the checkout that synced
  might not be the one settled, and eight others were dragged through a settle
  for a change that was never about them. Measured on this project before the
  fix — one checkout's answers current, eight frozen for two and a quarter
  hours while agents worked in them.

  ## Why both halves are asserted

  The "left alone" half on its own is satisfied by a graph that ignores file
  syncs entirely: every checkout's answers stay put, including the one that
  synced. So the checkout that reported files has to be shown moving first, and
  only then is the other one's stillness evidence of anything.

  ## Why the second checkout is the one that syncs

  It is the one holding a channel. The first checkout's files arrive through
  `:synced_context_component`, which syncs through the `/files` page before any
  rival exists — the sync targets the most recently active copy, so a second
  harness joining first would file those under the wrong one.

  Baselines are taken *after* the second checkout joins, deliberately. A copy
  appearing is itself a project-wide observation, so reading before the join
  would attribute its effects to the file sync under test.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.GraphReadHelpers
  import CodeMySpecSpex.SharedGivens
  import CodeMySpecSpex.WorkingCopyHelpers

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "A file sync moves the checkout it happened in", criterion: 1418 do
    scenario "Files syncing is about the checkout they synced from" do
      given_ :synced_context_component

      given_ "a second checkout on the same project, which has reported nothing",
             context do
        {:ok, second_root} = Briefly.create(directory: true)

        {reply, socket} = join_working_copy_socket(context, second_root, "the second checkout")
        second_id = reply["harness_id"] || reply[:working_copy_id]

        refute second_id == context.scope.active_working_copy_id,
               "two checkouts must be two copies; the server issued one id for both"

        {:ok,
         context
         |> Map.put(:second_id, second_id)
         |> Map.put(:second_socket, socket)
         |> Map.put(:first_id, context.scope.active_working_copy_id)}
      end

      given_ "what each checkout answers before anything is synced", context do
        {:ok,
         context
         |> Map.put(:first_before, verdicts(read_settled_graph(context, context.first_id)))
         |> Map.put(:second_before, verdicts(read_settled_graph(context, context.second_id)))}
      end

      when_ "the second checkout reports a file the first one already had", context do
        ref =
          Phoenix.ChannelTest.push(context.second_socket, "observations", %{
            "observations" => [
              %{
                "path" => "lib/example_context.ex",
                "role" => "implementation",
                "fingerprint" => "second-copy-has-it-too",
                "mtime" => "2026-09-17T00:00:00.000000Z"
              }
            ]
          })

        Phoenix.ChannelTest.assert_reply(ref, :ok, _summary, 2000)

        {:ok,
         context
         |> Map.put(:first_after, verdicts(read_settled_graph(context, context.first_id)))
         |> Map.put(:second_after, verdicts(read_settled_graph(context, context.second_id)))}
      end

      then_ "the checkout that synced answers differently than it did", context do
        refute context.second_after == context.second_before,
               """
               The checkout that reported the file answers exactly as it did
               before, so nothing was applied to it and the criterion below
               would pass for a graph that ignores file syncs entirely.

               before: #{inspect(context.second_before)}
               after:  #{inspect(context.second_after)}
               """

        {:ok, context}
      end

      then_ "and the checkout that did not sync answers exactly as it did", context do
        assert context.first_after == context.first_before,
               """
               A file synced in one checkout changed another checkout's answers.

               Nothing arrived in this copy. If its verdicts moved, the
               observation was applied to checkouts it was never about — which
               is both wrong and the whole-project recompute this path exists to
               avoid, wearing a different hat.

               before: #{inspect(context.first_before)}
               after:  #{inspect(context.first_after)}
               """

        {:ok, context}
      end
    end
  end

  # Every verdict in a graph read, as a sorted list, because the criterion is
  # about which checkout moved rather than about any one requirement. Details
  # ride along: a verdict that stays true while its reason changes underneath is
  # still an answer that moved.
  defp verdicts(graph) do
    (graph["nodes"] || [])
    |> Enum.map(
      &{&1["entity_type"], to_string(&1["entity_id"]), &1["name"], &1["satisfied"], &1["details"]}
    )
    |> Enum.sort()
  end
end
