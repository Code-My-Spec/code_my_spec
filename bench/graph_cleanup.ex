defmodule Bench.GraphCleanup do
  @moduledoc """
  Remove everything a graph benchmark wrote.

  The benchmarks run with the sandbox in `:auto` mode — the graph fans out into
  supervised tasks, and under ownership those die with `cannot find ownership
  process`. That means the rows are real, in the same database `mix test` uses,
  and they do not roll back.

  Skipping this once was enough: a leftover `bench-26850` account failed two
  account tests that assert on what is in the table, with no hint that a
  benchmark had been near it.
  """

  alias CodeMySpec.Repo

  @doc "Delete every project, component, story, file and account the benchmarks made."
  def run do
    # Ordered by foreign key rather than trusting a cascade. Stories are
    # deleted before their paper_trail versions, because the story row is what
    # points at the version.
    Repo.query!("""
    WITH bench_projects AS (SELECT id FROM projects WHERE name LIKE 'bench_%'),
         bench_components AS (
           SELECT id FROM components WHERE project_id IN (SELECT id FROM bench_projects)
         ),
         bench_stories AS (
           SELECT id FROM stories WHERE project_id IN (SELECT id FROM bench_projects)
         ),
         d1 AS (DELETE FROM files WHERE project_id IN (SELECT id FROM bench_projects)),
         d2 AS (
           DELETE FROM dependencies
           WHERE source_component_id IN (SELECT id FROM bench_components)
              OR target_component_id IN (SELECT id FROM bench_components)
         ),
         d3 AS (DELETE FROM stories WHERE id IN (SELECT id FROM bench_stories)),
         d4 AS (
           DELETE FROM versions
           WHERE item_type = 'Story' AND item_id IN (SELECT id FROM bench_stories)
         ),
         d5 AS (DELETE FROM components WHERE id IN (SELECT id FROM bench_components)),
         d6 AS (DELETE FROM projects WHERE id IN (SELECT id FROM bench_projects))
    DELETE FROM accounts WHERE name LIKE 'bench-%'
    """)

    :ok
  end
end
