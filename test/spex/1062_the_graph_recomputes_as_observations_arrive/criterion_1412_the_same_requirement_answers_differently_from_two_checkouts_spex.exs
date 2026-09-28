defmodule CodeMySpecSpex.Story1062.Criterion3497Spex do
  @moduledoc """
  Story 1062 — The graph recomputes as observations arrive.
  Criterion 3497 — The same requirement answers differently from two checkouts.

  Rule: a requirement's answer is a statement about one checkout.

  ## The claim the routing rests on

  3503 and 3506 are about *where an observation lands*. Neither of them means
  anything unless this is true first: that one requirement genuinely has two
  answers at once, because two checkouts can see different trees.

  If a verdict were a property of the project, routing would be a performance
  question and getting it wrong would cost time rather than correctness. It is
  not. `Preloader.load/1` scopes its file query to one checkout, so "this
  component has an implementation" is only ever true *from somewhere*, and the
  graph stores one row per requirement per checkout to say so.

  ## Why it is asserted by reading rather than by writing

  There is no action in the `when_`. The two checkouts already disagree the
  moment one of them has a file the other does not, and inventing a write to
  trigger it would be asserting the writer instead of the claim.

  What makes that a real difference rather than a missing row is the pair of
  assertions: the requirement has to be *present* at both vantages and answer
  differently. A checkout that simply has no rows would satisfy "they differ"
  while meaning nothing, so the absent case is checked for by name and fails
  loudly rather than reading as disagreement.

  ## What it would catch

  A blended read. `Preloader`'s own moduledoc measured that failure at 303
  components — an unscoped load returns every checkout's row for a path, so a
  file present in any worktree reads as present in all of them, and an agent is
  told work is done that nobody has done in its tree. That is the direction
  that costs the most, and it looks identical to success from anywhere except a
  second checkout.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.GraphReadHelpers
  import CodeMySpecSpex.SharedGivens
  import CodeMySpecSpex.WorkingCopyHelpers

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "A verdict is a statement about one checkout, not about the project", criterion: 1412 do
    scenario "The same requirement answers differently from two checkouts" do
      given_ :synced_context_component

      given_ "a second checkout that has reported no files of its own", context do
        {:ok, second_root} = Briefly.create(directory: true)
        {reply, _socket} = join_working_copy_socket(context, second_root, "the second checkout")
        second_id = reply["harness_id"] || reply[:working_copy_id]

        refute second_id == context.scope.active_working_copy_id,
               "two checkouts must be two copies; the server issued one id for both"

        {:ok,
         context
         |> Map.put(:second_id, second_id)
         |> Map.put(:first_id, context.scope.active_working_copy_id)}
      end

      when_ "the same requirement is answered from each checkout", context do
        component_id = context.component.id

        {:ok,
         context
         |> Map.put(
           :from_first,
           implementation(read_settled_graph(context, context.first_id), component_id)
         )
         |> Map.put(
           :from_second,
           implementation(read_settled_graph(context, context.second_id), component_id)
         )}
      end

      then_ "both checkouts carry an answer for it", context do
        refute is_nil(context.from_first),
               "the checkout holding the file has no implementation_file row at all"

        refute is_nil(context.from_second),
               """
               The second checkout has no implementation_file row for this
               component, so the difference asserted below would be a missing
               row rather than a different answer.
               """

        {:ok, context}
      end

      then_ "the checkout holding the file says it is there", context do
        assert context.from_first == true,
               "this checkout synced the implementation and answers #{inspect(context.from_first)}"

        {:ok, context}
      end

      then_ "and the checkout without it says it is not", context do
        assert context.from_second == false,
               """
               A checkout that has never reported this file answers
               #{inspect(context.from_second)}.

               The file exists in the other worktree and in no tree this
               checkout can see. Reading it as present here is the blended read
               `Preloader` measured at 303 components — an agent told the work
               is done, in a tree where nobody has done it.
               """

        {:ok, context}
      end
    end
  end

  # One component's `implementation_file` verdict as a checkout sees it, or
  # `nil` when the requirement is not projected there. `nil` is distinguished
  # from `false` on purpose: a missing row and a negative answer fail for
  # completely different reasons.
  defp implementation(graph, component_id) do
    (graph["nodes"] || [])
    |> Enum.find(
      &(&1["entity_type"] == "component" and
          to_string(&1["entity_id"]) == to_string(component_id) and
          &1["name"] == "implementation_file")
    )
    |> verdict_of()
  end

  defp verdict_of(nil), do: nil
  defp verdict_of(node), do: node["satisfied"]
end
