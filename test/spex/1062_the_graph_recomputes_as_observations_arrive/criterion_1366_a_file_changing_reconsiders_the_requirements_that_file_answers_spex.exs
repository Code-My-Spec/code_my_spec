defmodule CodeMySpecSpex.Story1062.Criterion3426Spex do
  @moduledoc """
  Story 1062 — The graph recomputes as observations arrive.
  Criterion 3426 — A file changing moves the verdicts that file answers in that
  copy's graph, and only that copy's.

  Rule: a copy's file verdicts are read from that copy's files. A file going
  away moves the verdict it answers at that copy; a component in another family
  keeps its verdict, and another checkout's graph reads its own files.

  Two contexts, each with its own child, gives two families. The change lands
  in one of them, in one checkout.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.GraphGivens
  import CodeMySpecSpex.GraphReadHelpers
  import CodeMySpecSpex.WorkingCopyHelpers

  alias CodeMySpecSpex.Fixtures
  alias CodeMySpecSpex.GraphContentFixtures, as: Content

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "A file changing moves the verdicts that file answers in that copy's graph, and only that copy's",
    criterion: 1366 do
    scenario "one component's implementation file goes away in one checkout" do
      given_ :cross_context_dependency

      given_ "a second checkout of the same project", context do
        root = CodeMySpec.TempFile.owned_dir("test")
        {reply, _socket} = join_working_copy_socket(context, root, "the second checkout")
        second_id = reply["harness_id"] || reply[:working_copy_id]

        refute second_id == context.scope.active_working_copy_id,
               "two checkouts must be two copies; the server issued one id for both"

        {:ok, Map.put(context, :second_id, second_id)}
      end

      given_ "both components read as implemented here", context do
        here = read_settled_graph(context, context.scope.active_working_copy_id)

        assert implemented(here, context.users_child.id) == true,
               "the premise did not hold: the component losing its file is not implemented"

        assert implemented(here, context.stories_child.id) == true,
               "the premise did not hold: the other family's component is not implemented"

        other = read_settled_graph(context, context.second_id)
        {:ok, Map.put(context, :other_before, implemented(other, context.users_child.id))}
      end

      when_ "one component's implementation file goes away and the checkout scans", context do
        :ok =
          Fixtures.delete_env_file(
            context.execution_context,
            Content.impl_path(context.users_child.module_name)
          )

        :ok = Fixtures.scan_working_copy(context.scope)

        {:ok,
         context
         |> Map.put(:here, read_settled_graph(context, context.scope.active_working_copy_id))
         |> Map.put(:other, read_settled_graph(context, context.second_id))}
      end

      then_ "that checkout reads the component's file as missing", context do
        assert implemented(context.here, context.users_child.id) == false,
               """
               A component's implementation file went away and this checkout
               still reads it as present. The checkout's file verdicts are read
               from its files; this one did not follow them.
               """

        {:ok, context}
      end

      then_ "and a component in another family keeps its verdict", context do
        assert implemented(context.here, context.stories_child.id) == true,
               "a file in one family moved the verdict of a component in another"

        {:ok, context}
      end

      then_ "and another checkout's graph does not move", context do
        assert implemented(context.other, context.users_child.id) == context.other_before,
               """
               A file went away in one checkout and another checkout's verdict
               for that component moved. Each checkout's file verdicts are read
               from its own files.
               """

        {:ok, context}
      end
    end
  end

  defp implemented(graph, component_id),
    do: satisfaction_of(graph, "implementation_file", "component", component_id)
end
