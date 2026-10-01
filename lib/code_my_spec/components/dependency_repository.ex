defmodule CodeMySpec.Components.DependencyRepository do
  @moduledoc """
  Repository for Dependency data access.
  """

  import Ecto.Query, warn: false
  alias CodeMySpec.Components.{Component, Dependency}
  alias CodeMySpec.Repo
  alias CodeMySpec.Requirements.GraphInputs
  alias CodeMySpec.Users.Scope

  @doc """
  Returns the list of dependencies for components in the given scope.
  """
  @spec list_dependencies(Scope.t()) :: [Dependency.t()]
  def list_dependencies(%Scope{active_project_id: project_id}) do
    from(d in Dependency,
      join: sc in Component,
      on: d.source_component_id == sc.id,
      where: sc.project_id == ^project_id,
      preload: [:source_component, :target_component]
    )
    |> Repo.all()
  end

  @doc """
  Returns the list of dependencies for a specific component (outgoing dependencies).
  """
  @spec list_component_dependencies(Scope.t(), binary()) :: [Dependency.t()]
  def list_component_dependencies(%Scope{active_project_id: project_id}, component_id) do
    from(d in Dependency,
      join: sc in Component,
      on: d.source_component_id == sc.id,
      where: sc.project_id == ^project_id and d.source_component_id == ^component_id,
      preload: [:target_component]
    )
    |> Repo.all()
  end

  @doc """
  Gets a single dependency by ID within scope.
  """
  @spec get_dependency!(Scope.t(), non_neg_integer()) :: Dependency.t()
  def get_dependency!(%Scope{active_project_id: project_id}, id) do
    from(d in Dependency,
      join: sc in Component,
      on: d.source_component_id == sc.id,
      where: d.id == ^id and sc.project_id == ^project_id,
      preload: [:source_component, :target_component]
    )
    |> Repo.one!()
  end

  @doc """
  The dependency of `source_id` on `target_id` within scope, or nil. Ids that
  are not UUIDs find nothing rather than raising.
  """
  @spec get_dependency_between(Scope.t(), term(), term()) :: Dependency.t() | nil
  def get_dependency_between(%Scope{active_project_id: project_id}, source_id, target_id) do
    with {:ok, source} <- Ecto.UUID.cast(source_id),
         {:ok, target} <- Ecto.UUID.cast(target_id) do
      from(d in Dependency,
        join: sc in Component,
        on: d.source_component_id == sc.id,
        where:
          sc.project_id == ^project_id and d.source_component_id == ^source and
            d.target_component_id == ^target,
        preload: [:source_component, :target_component]
      )
      |> Repo.one()
    else
      :error -> nil
    end
  end

  @doc """
  Creates a dependency.
  """
  @spec create_dependency(Scope.t(), map()) ::
          {:ok, Dependency.t()} | {:error, Ecto.Changeset.t()}
  def create_dependency(%Scope{} = scope, attrs) do
    %Dependency{}
    |> Dependency.changeset(attrs)
    |> Repo.insert()
    |> announce(scope)
  end

  @doc """
  Deletes a dependency.
  """
  @spec delete_dependency(Scope.t(), Dependency.t()) ::
          {:ok, Dependency.t()} | {:error, Ecto.Changeset.t()}
  def delete_dependency(%Scope{} = scope, %Dependency{} = dependency) do
    dependency |> Repo.delete() |> announce(scope)
  end

  @doc """
  Deletes a dependency.
  """
  @spec delete_dependency(Dependency.t()) ::
          {:ok, Dependency.t()} | {:error, Ecto.Changeset.t()}
  def delete_dependency(%Dependency{} = dependency) do
    dependency |> Repo.delete() |> announce(project_of(dependency))
  end

  # A dependency moves edges: the cross-context edge between the two
  # components, and every story kickoff drawn through them. No verdict reads
  # it, so the kind is handled as moving nothing and the projector redraws the
  # edges for it (`Handlers.shape_kinds/0`). Named after the source, which is
  # the entity the edge hangs off. Project-wide as every component fact is:
  # `dependencies` has no `working_copy_id`.
  defp announce({:ok, %Dependency{} = dependency} = result, scope_or_project_id)
       when not is_nil(scope_or_project_id) do
    GraphInputs.event(
      scope_or_project_id,
      "Components",
      "dependency_changed",
      %{},
      [{"component", dependency.source_component_id}],
      :project_wide
    )

    result
  end

  defp announce(result, _scope_or_project_id), do: result

  defp project_of(%Dependency{source_component_id: id}),
    do: Repo.one(from(c in Component, where: c.id == ^id, select: c.project_id))

  @doc """
  Simple circular dependency check — looks for direct cycles between
  architectural components.

  Skips dependency pairs where either side is a schema. Ecto's
  `has_many`/`belongs_to` association pairs are bidirectional by
  design (Account ↔ Member, Persona ↔ PersonaStory) and are not
  architectural cycles. Flagging them as cycles trains callers to
  ignore the output, masking real cycles between contexts.
  """
  @spec validate_dependency_graph(Scope.t()) :: :ok | {:error, list()}
  # Every cycle, not only mutual pairs.
  #
  # This was a self-join matching `A -> B` against `B -> A`, so it saw cycles of
  # length two and nothing else — while reporting "detected cycles", which reads
  # as complete. Measured on this project: 32 cycles in the dependency graph, of
  # which the self-join found 17. Among the fifteen it missed were
  # `Components -> Documents -> Requirements -> Components` and a six-hop
  # `AgentTasks -> Sessions -> Interaction -> InteractionsRepository ->
  # Session -> SessionType -> AgentTasks`. (That path is the graph as it stood
  # at the measurement; the `Interaction` modules in it were deleted by
  # `1742e187` and no longer exist to grep for.)
  #
  # That matters beyond tidiness. `d10f65e8` measured a cyclic context
  # dependency graph at 877 seconds of edge computation against 4 for the
  # acyclic equivalent, and recorded the project's count as 4 — so it grew
  # eightfold while the check said what it always said.
  #
  # `:digraph` rather than a recursive query: the traversal is in memory over a
  # graph this size (599 components, 1,508 edges here) and finishing in well
  # under a second, and `get_short_cycle/2` gives the shortest cycle through
  # each vertex, which is the one a person can act on.
  def validate_dependency_graph(%Scope{active_project_id: project_id}) do
    edges =
      from(d in Dependency,
        join: sc in Component,
        on: d.source_component_id == sc.id,
        join: tc in Component,
        on: d.target_component_id == tc.id,
        where: sc.project_id == ^project_id,
        where: sc.type != "schema" and tc.type != "schema",
        select: {sc, tc}
      )
      |> Repo.all()

    case find_cycles(edges) do
      [] -> :ok
      cycles -> {:error, cycles}
    end
  end

  defp find_cycles(edges) do
    graph = :digraph.new()

    by_id =
      Enum.reduce(edges, %{}, fn {source, target}, acc ->
        acc |> Map.put(source.id, source) |> Map.put(target.id, target)
      end)

    for {source, target} <- edges do
      :digraph.add_vertex(graph, source.id)
      :digraph.add_vertex(graph, target.id)
      :digraph.add_edge(graph, source.id, target.id)
    end

    cycles =
      graph
      |> :digraph.vertices()
      |> Enum.map(&:digraph.get_short_cycle(graph, &1))
      |> Enum.reject(&(&1 == false))
      # `get_short_cycle/2` repeats the start vertex at the end; drop it, then
      # dedup by membership so one ring is reported once rather than once per
      # vertex on it.
      |> Enum.map(&Enum.uniq/1)
      |> Enum.uniq_by(&Enum.sort/1)
      |> Enum.map(fn ids -> format_cycle(ids, by_id) end)

    :digraph.delete(graph)
    cycles
  end

  defp format_cycle(ids, by_id) do
    components = Enum.map(ids, &Map.fetch!(by_id, &1))

    %{
      components: Enum.map(components, &component_summary/1),
      path: Enum.map(components, & &1.name)
    }
  end

  @doc """
  Basic topological sort - components with no dependencies first.
  """
  @spec resolve_dependency_order(Scope.t()) :: {:ok, [Component.t()]}
  def resolve_dependency_order(%Scope{active_project_id: project_id}) do
    components_with_deps =
      from(c in Component,
        left_join: d in Dependency,
        on: d.source_component_id == c.id,
        where: c.project_id == ^project_id,
        group_by: c.id,
        select: {c, count(d.id)}
      )
      |> Repo.all()

    sorted =
      components_with_deps
      |> Enum.sort_by(&elem(&1, 1))
      |> Enum.map(&elem(&1, 0))

    {:ok, sorted}
  end

  defp component_summary(component) do
    %{
      id: component.id,
      name: component.name,
      type: component.type,
      module_name: component.module_name
    }
  end
end
