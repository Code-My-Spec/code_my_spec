# Requirement-graph cost against project size.
#
# The question this answers is not "how fast is it" but "does it get worse
# faster than projects get bigger". A flat or linear curve means the current
# cost is the cost; a curve that bends upward means today's number is a
# statement about today's data and nothing else.
#
#     MIX_ENV=test mix run bench/graph.exs
#
# Sizes come from BENCH_SIZES if you want a different sweep.

Code.require_file("bench/graph_seed.ex")
Code.require_file("bench/graph_cleanup.ex")

alias Bench.{GraphCleanup, GraphSeed}
alias CodeMySpec.Repo
alias CodeMySpec.Requirements.RequirementGraph

# `:auto`, not a checkout: the graph fans out into supervised tasks, and under
# ownership those die with `cannot find ownership process`. Nothing here needs
# isolation — the benchmark seeds its own projects and reads only those.
Ecto.Adapters.SQL.Sandbox.mode(Repo, :auto)

sizes =
  case System.get_env("BENCH_SIZES") do
    nil -> [100, 400, 1600, 3200]
    raw -> raw |> String.split(",") |> Enum.map(&String.to_integer(String.trim(&1)))
  end

# One account for every synthetic project.
account_id = Ecto.UUID.generate()
now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

Repo.insert_all("accounts", [
  %{
    id: Ecto.UUID.dump!(account_id),
    name: "bench-#{System.unique_integer([:positive])}",
    inserted_at: now,
    updated_at: now
  }
])

IO.puts("seeding #{Enum.join(sizes, ", ")} components…")

scopes =
  Map.new(sizes, fn size ->
    # Depth pinned at the real project's measured 9. Letting it grow with size
    # — which an earlier version did by accident — benchmarks the dependency
    # chain rather than the project, and turns a linear curve into a cliff.
    {us, scope} = :timer.tc(fn -> GraphSeed.build(account_id, size, dep_layers: 9) end)

    IO.puts("  #{size}: seeded in #{Float.round(us / 1_000_000, 1)}s")

    {size, scope}
  end)

# Shape report first — the numbers below only mean something next to it.
IO.puts("\nshape:")

Enum.each(sizes, fn size ->
  scope = Map.fetch!(scopes, size)
  {{nodes, edges, _}, metrics} = RequirementGraph.compute_graph_with_actionable_metrics(scope)

  IO.puts(
    "  #{String.pad_leading(to_string(size), 5)} components -> " <>
      "#{length(nodes)} nodes, #{length(edges)} edges  " <>
      "(preload #{metrics.preload_ms}ms, nodes #{metrics.compute_nodes_ms}ms, " <>
      "edges #{metrics.compute_edges_ms}ms, actionable #{metrics.actionable_ms}ms)"
  )
end)

IO.puts("")

Benchee.run(
  Map.new(sizes, fn size ->
    scope = Map.fetch!(scopes, size)
    {"#{size} components", fn -> RequirementGraph.compute_graph_with_actionable(scope) end}
  end),
  time: 5,
  warmup: 2,
  memory_time: 1,
  print: [fast_warning: false]
)

GraphCleanup.run()
IO.puts("\nbenchmark data removed")
