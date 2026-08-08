# Requirement-graph cost against dependency *depth*, at a fixed project size.
#
# Size turned out not to be the variable that matters. Cross-context edges are
# built over each component's transitive dependency closure, so the cost is
# driven by how deep the context dependency chain runs — not how many
# components or dependencies exist.
#
# The real project (845 components, 407 dependencies) measures a maximum
# dependency depth of 9 and an average of 4.34. This sweeps around that number
# so the headroom is a measurement rather than a guess.
#
#     MIX_ENV=test mix run bench/graph_depth.exs

Code.require_file("bench/graph_seed.ex")
Code.require_file("bench/graph_cleanup.ex")

alias Bench.{GraphCleanup, GraphSeed}
alias CodeMySpec.Repo
alias CodeMySpec.Requirements.RequirementGraph

Ecto.Adapters.SQL.Sandbox.mode(Repo, :auto)

size = String.to_integer(System.get_env("BENCH_SIZE") || "800")

depths =
  case System.get_env("BENCH_DEPTHS") do
    nil -> [3, 6, 9, 12, 16, 24]
    raw -> raw |> String.split(",") |> Enum.map(&String.to_integer(String.trim(&1)))
  end

account_id = Ecto.UUID.generate()
now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

Repo.insert_all("accounts", [
  %{
    id: Ecto.UUID.dump!(account_id),
    name: "bench-depth-#{System.unique_integer([:positive])}",
    inserted_at: now,
    updated_at: now
  }
])

IO.puts("#{size} components, dependency depth swept over #{Enum.join(depths, ", ")}")
IO.puts("(the real 845-component project measures depth 9, average 4.34)\n")

IO.puts(
  String.pad_trailing("depth", 8) <>
    String.pad_leading("edges", 12) <>
    String.pad_leading("edges_ms", 12) <>
    String.pad_leading("total_ms", 12)
)

Enum.each(depths, fn depth ->
  scope = GraphSeed.build(account_id, size, dep_layers: depth)

  {us, {{_nodes, edges, _}, metrics}} =
    :timer.tc(fn -> RequirementGraph.compute_graph_with_actionable_metrics(scope) end)

  IO.puts(
    String.pad_trailing(to_string(depth), 8) <>
      String.pad_leading(to_string(length(edges)), 12) <>
      String.pad_leading(to_string(metrics.compute_edges_ms), 12) <>
      String.pad_leading(to_string(div(us, 1000)), 12)
  )
end)

GraphCleanup.run()
IO.puts("\nbenchmark data removed")
