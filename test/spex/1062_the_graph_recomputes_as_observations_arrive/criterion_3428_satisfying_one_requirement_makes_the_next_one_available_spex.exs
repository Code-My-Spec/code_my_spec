defmodule CodeMySpecSpex.Story1062.Criterion3428Spex do
  @moduledoc """
  Satisfying component implementations makes a story's BDD work available.

  The story's own inputs stay fixed while two child implementations appear.
  Its frontier must move even though only the components' files changed.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.GraphGivens
  import CodeMySpecSpex.GraphReadHelpers

  alias CodeMySpecSpex.Fixtures

  setup :register_log_in_setup_account
  setup :setup_active_project

  @children [
    {"Reservations.BookingRepo", "lib/reservations/booking_repo.ex"},
    {"Reservations.PricingService", "lib/reservations/pricing_service.ex"}
  ]

  spex "Work unblocked by somebody else's work is offered" do
    scenario "a context's children finish implementation" do
      given_ :context_with_three_children_in_satisfied_project

      given_ "a graph whose frontier has reached the children", context do
        for {_module, path} <- @children do
          :ok = CodeMySpec.Environments.delete_file(context.environment, path)
        end

        :ok = Fixtures.scan_working_copy(context.scope)
        warm = read_settled_graph(context)

        {:ok,
         context
         |> Map.put(:before_graph, warm)
         |> Map.put(:before, Fixtures.next_actionable_requirements(context.scope))}
      end

      when_ "each child gets its implementation file and the project scans", context do
        for {module_name, path} <- @children do
          :ok =
            Fixtures.write_env_file(
              context.environment,
              path,
              "defmodule #{module_name} do\nend\n"
            )
        end

        :ok = Fixtures.scan_working_copy(context.scope)

        _settled = read_settled_graph(context)

        {:ok, Map.put(context, :after, Fixtures.next_actionable_requirements(context.scope))}
      end

      then_ "the story's specs were not on offer before", context do
        refute offered?(context.before, "Reservations story", "bdd_specs_passing"),
               """
               The premise did not hold: the story's `bdd_specs_passing` was
               already available before the components finished.

               edges before: #{length(context.before_graph["edges"] || [])}
               story edges before: #{inspect(story_edges(context.before_graph))}
               children's implementation_file before: #{inspect(children_verdicts(context.before_graph))}

               Then nothing below is about a prerequisite moving — the
               requirement was never blocked, and a graph that ignores
               prerequisites entirely would pass.

               offered before: #{inspect(offered(context.before))}
               """

        {:ok, context}
      end

      then_ "and they are now", context do
        assert offered?(context.after, "Reservations story", "bdd_specs_passing"),
               """
               The components finished and the work that unblocks was not
               offered.

               Nothing about the story changed — same criteria, same rules, same
               personas, same files, same fingerprint. Only the components it
               depends on moved. A pass that recomputes an entity when its own
               sources move and never walks the edges leaves this requirement
               exactly as it was, and an agent asking what to do next is told
               about everything except the thing that just became possible.

               offered after: #{inspect(offered(context.after))}
               """

        {:ok, context}
      end
    end
  end

  defp story_edges(graph) do
    Enum.filter(graph["edges"] || [], fn e -> String.contains?(inspect(e), "story") end)
  end

  defp children_verdicts(graph) do
    (graph["nodes"] || [])
    |> Enum.filter(&(&1["name"] == "implementation_file"))
    |> Enum.map(&{&1["entity_name"], &1["satisfied"]})
  end

  defp offered?(requirements, entity_name, name) do
    Enum.any?(requirements, &(&1.entity_name == entity_name and to_string(&1.name) == name))
  end

  defp offered(requirements) do
    requirements |> Enum.map(&{&1.entity_name, to_string(&1.name)}) |> Enum.sort()
  end
end
