defmodule Bench.GraphSeed do
  @moduledoc """
  Builds synthetic projects of a chosen size for the requirement-graph
  benchmark.

  Direct `insert_all` rather than fixtures: the point is to reach sizes several
  times larger than any real project, and one changeset per row does not get
  there in reasonable time. Nothing here validates, because nothing here is
  under test — the graph is.

  Shape matters more than volume. The graph's cost is driven by how components
  connect, not how many rows exist, so this reproduces the real structure:
  contexts holding children, dependencies between contexts, stories attached to
  surfaces, and files under components. A flat list of unconnected components
  would benchmark almost nothing.
  """

  alias CodeMySpec.Repo
  alias CodeMySpec.Stories
  alias CodeMySpec.Users.Scope

  @children_per_context 4
  @deps_per_context 3
  @files_per_component 2

  @doc """
  Insert a project with roughly `component_count` components, wired up.

  Returns a `Scope` with the project loaded — the graph and the story context
  both match on the struct, not the id.
  """
  def build(account_id, component_count, opts \\ []) do
    dep_layers = Keyword.get(opts, :dep_layers, 9)
    project_id = Ecto.UUID.generate()
    now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

    Repo.insert_all("projects", [
      %{
        id: Ecto.UUID.dump!(project_id),
        name: "bench_#{component_count}_#{System.unique_integer([:positive])}",
        account_id: Ecto.UUID.dump!(account_id),
        status: "ready",
        inserted_at: now,
        updated_at: now
      }
    ])

    contexts = div(component_count, @children_per_context + 1)
    context_ids = insert_contexts(project_id, account_id, contexts, now)
    child_ids = insert_children(project_id, account_id, context_ids, now)

    insert_dependencies(context_ids, dep_layers, now)
    scope = insert_stories(project_id, account_id, context_ids, now)
    insert_files(project_id, context_ids ++ child_ids, now)

    scope
  end

  defp insert_contexts(project_id, account_id, count, now) do
    rows =
      for i <- 1..count do
        %{
          id: Ecto.UUID.bingenerate(),
          name: "Ctx#{i}",
          module_name: "Bench.Ctx#{i}",
          type: "context",
          description: "bench context",
          project_id: Ecto.UUID.dump!(project_id),
          account_id: Ecto.UUID.dump!(account_id),
          parent_component_id: nil,
          inserted_at: now,
          updated_at: now
        }
      end

    Repo.insert_all("components", rows)
    Enum.map(rows, & &1.id)
  end

  defp insert_children(project_id, account_id, context_ids, now) do
    rows =
      for {ctx_id, i} <- Enum.with_index(context_ids),
          c <- 1..@children_per_context do
        %{
          id: Ecto.UUID.bingenerate(),
          name: "Ctx#{i}Child#{c}",
          module_name: "Bench.Ctx#{i}.Child#{c}",
          type: "schema",
          description: "bench child",
          project_id: Ecto.UUID.dump!(project_id),
          account_id: Ecto.UUID.dump!(account_id),
          parent_component_id: ctx_id,
          inserted_at: now,
          updated_at: now
        }
      end

    Repo.insert_all("components", rows)
    Enum.map(rows, & &1.id)
  end

  # Each context depends on a few later ones — strictly forward, so the
  # dependency graph is a DAG.
  #
  # The direction matters more than the count. An earlier version wrapped
  # around (`rem(i + d * 7, count)`), which made the contexts one big cycle
  # where every context reached every other. Cross-context edges are built over
  # the transitive dependency closure, so that produced 52,654 graph edges from
  # 400 components where the real 845-component project has 4,624 — twenty-four
  # times denser than anything real, and it benchmarked the ring rather than
  # the code.
  #
  # Real dependency graphs are layered: contexts depend downward on the ones
  # they are built from, and the chain bottoms out after a handful of hops.
  #
  # Depth is the parameter that matters, so it is the parameter. A previous
  # version chained `i -> i+1, i+2, i+3`, which is a dependency chain as deep
  # as the context count — 160 hops at 800 components, against a measured 9 in
  # the real project. Cross-context edges span the whole transitive closure, so
  # that one detail produced 106,093 graph edges where the real project of the
  # same size has 4,624.
  #
  # Contexts are dealt into `layers` bands and depend only on the next band, so
  # the longest chain is exactly `layers`.
  defp insert_dependencies(context_ids, layers, now) do
    count = length(context_ids)
    bands = max(layers, 1)
    per_band = max(div(count, bands), 1)

    banded = Enum.group_by(Enum.with_index(context_ids), fn {_id, i} -> div(i, per_band) end)

    rows =
      for band <- 0..(bands - 2),
          {source_id, _} <- Map.get(banded, band, []),
          {target_id, _} <- Enum.take(Map.get(banded, band + 1, []), @deps_per_context) do
        %{
          source_component_id: source_id,
          target_component_id: target_id,
          inserted_at: now,
          updated_at: now
        }
      end

    Repo.insert_all("dependencies", rows)
  end

  # Through the context, not `insert_all`: `stories` carries paper_trail's
  # `first_version_id`/`current_version_id` as NOT NULL, so a raw insert cannot
  # produce a valid row. Seeding is paid once per benchmark run, so the slower
  # path costs nothing that matters.
  defp insert_stories(project_id, account_id, context_ids, _now) do
    # `create_story/2` matches on a loaded project, not on the id.
    project = Repo.get!(CodeMySpec.Projects.Project, project_id)

    scope = %Scope{
      active_project: project,
      active_project_id: project_id,
      active_account_id: account_id
    }

    Enum.each(Enum.with_index(context_ids), fn {ctx_id, i} ->
      {:ok, _} =
        Stories.create_story(scope, %{
          title: "Bench story #{i}",
          description: "bench",
          status: "in_progress",
          ready_for_dev: true,
          priority: i,
          component_id: Ecto.UUID.load!(ctx_id)
        })
    end)

    scope
  end

  defp insert_files(project_id, component_ids, now) do
    rows =
      for {comp_id, i} <- Enum.with_index(component_ids),
          f <- 1..@files_per_component do
        %{
          path: "lib/bench/c#{i}_#{f}.ex",
          role: if(f == 1, do: "implementation", else: "test"),
          fingerprint: "fp#{i}_#{f}",
          valid: true,
          component_id: comp_id,
          project_id: Ecto.UUID.dump!(project_id),
          inserted_at: now,
          updated_at: now
        }
      end

    Repo.insert_all("files", rows)
  end
end
