defmodule CodeMySpecSpex.Story1062.Criterion3448Spex do
  @moduledoc "A clean analyzer run does not rebuild implementation requirements."
  use CodeMySpecSpex.Case
  import CodeMySpecSpex.GraphGivens
  import CodeMySpecSpex.GraphReadHelpers
  alias CodeMySpecSpex.Fixtures
  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Analysis completion leaves component work alone" do
    scenario "a run finishes without changing files or findings" do
      given_ :context_with_three_children_in_satisfied_project

      given_ "settled component verdicts with observable timestamps", context do
        _ = read_settled_graph(context)
        :ok = Fixtures.backdate_requirement_freshness(context.scope)
        before = components(read_settled_graph(context))
        assert before != []
        cutoff = NaiveDateTime.add(NaiveDateTime.utc_now(), -60, :second)

        assert Enum.all?(before, fn {_id, _name, _satisfied, at} ->
                 NaiveDateTime.compare(NaiveDateTime.from_iso8601!(at), cutoff) == :lt
               end)

        {:ok, Map.put(context, :before, before)}
      end

      when_ "clean analyzer results arrive", context do
        Fixtures.fresh_analysis_runs(context.scope)
        {:ok, Map.put(context, :after, components(read_settled_graph(context)))}
      end

      then_ "component verdicts and their computed timestamps are unchanged", context do
        assert context.after == context.before
        {:ok, context}
      end
    end
  end

  defp components(graph) do
    graph["nodes"]
    |> Enum.filter(&(&1["entity_type"] == "component"))
    |> Enum.map(&{&1["entity_id"], &1["name"], &1["satisfied"], &1["checked_at"]})
    |> Enum.sort()
  end
end
