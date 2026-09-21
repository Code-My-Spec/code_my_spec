defmodule CodeMySpec.Components do
  @moduledoc """
  Manages component definitions, metadata, type classification, and inter-component dependencies for architectural design.
  """

  use Boundary,
    top_level?: true,
    deps: [
      CodeMySpec.Accounts,
      CodeMySpec.Paths,
      CodeMySpec.Projects,
      CodeMySpec.Repo,
      CodeMySpec.Requirements,
      CodeMySpec.Stories,
      CodeMySpec.Users
    ],
    exports: :all

  alias CodeMySpec.Components.{
    Component,
    ComponentRepository,
    DependencyRepository
  }

  alias CodeMySpec.Requirements.GraphInputs
  alias CodeMySpec.Requirements.Registry, as: RequirementsRegistry
  alias CodeMySpec.Users.Scope

  @doc """
  Subscribes to scoped notifications about any component changes.

  The broadcasted messages match the pattern:

    * {:created, %Component{}}
    * {:updated, %Component{}}
    * {:deleted, %Component{}}

  """
  def subscribe_components(%Scope{} = scope) do
    key = scope.user.id

    Phoenix.PubSub.subscribe(CodeMySpec.PubSub, "user:#{key}:components")
  end

  # The PubSub message always — the UI wants every change — and the graph
  # event only when `graph:` says the graph has something to read.
  defp broadcast(%Scope{} = scope, message, opts \\ []) do
    key = scope.user.id

    Phoenix.PubSub.broadcast(CodeMySpec.PubSub, "user:#{key}:components", message)

    if Keyword.get(opts, :graph, true) do
      kind = component_event_kind(message)
      GraphInputs.event(scope, "Components", kind, %{}, graph_entities(message), vantage_of(kind))
    end

    :ok
  end

  # Every checkout, whatever the kind. A component is a project fact: the
  # `components` table has no `working_copy_id`, and every vantage projects
  # rows for every component from the row's type, parent and dependencies.
  #
  # Creation and deletion were project-wide already — measured on dev,
  # 2026-09-17: ten components created in five minutes and every vantage but
  # the creator sat at `missing 4-6` rows. A *change* was narrowed to the
  # checkout on the reasoning that its files are read per checkout, which is
  # true of the files and not of the row: a retype moves the template and a
  # new dependency moves the edges at every vantage. The event path narrows a
  # drain to the checkouts its marks name, so a change marked for one checkout
  # left the others — the UI's vantage first among them — with the component
  # they knew before, and nothing ever told them otherwise. Per-checkout
  # effects of the same scan arrive as `files_synced`, marked per checkout.
  defp vantage_of(_kind), do: :project_wide

  # The component, and its parent.
  #
  # The parent is not incidental: `Freshness.component/2` hashes
  # `children_by_parent`, so a child appearing or disappearing moves the
  # *context's* requirements — a context's answer depends on which children it
  # has, though not on what changed inside them. A writer that named only the
  # component would leave the parent stale with nothing to say so, which is the
  # silent direction.
  # An entity appearing or going falls back to a recompute, deliberately.
  #
  # Handlers *settle* rows; they do not create them. `Shadow.sweep/2` and
  # `put_verdict/2` are both `UPDATE`s, and a story that has never been
  # projected has no rows for them to touch — so an event the projector handles
  # discards its fallback marks and the new story is never computed at all.
  # Caught by the shadow diff: three rows `missing` for a story created after
  # the seed.
  #
  # So creation and deletion emit a kind nothing handles, which leaves the marks
  # standing and sends the entity through `compute_entity/4` — the only path
  # that writes rows that did not exist, and the only one that reaps the rows of
  # an entity that is gone.
  defp component_event_kind({:created, _}), do: "component_created"
  defp component_event_kind({:deleted, _}), do: "component_deleted"
  defp component_event_kind(_message), do: "component_changed"

  # `:project` as well, because `architecture_designed` reads the component set
  # — its orphan rule asks which contexts are story-linked, descended from one,
  # or depended on by one. A component appearing, moving parent or changing type
  # can move that verdict.
  #
  # Only when the component appears or goes. A *change* to a component moves
  # its own template and edges and nothing of its parent's — `Freshness`
  # hashes the parent's children by id, not by content — and naming the parent
  # sent the whole family of the parent's own root through a recompute at
  # every vantage for a child's retype.
  #
  # The component and nothing else — not its parent, not the project.
  #
  # Not the parent: a component's unit of computation is its family, rooted
  # at its parent — `Preloader.load_component_family/3` loads the parent and
  # every sibling and instantiates the parent's template over them, which is
  # where the child's own nodes come from. Naming the parent as well named
  # *its* family, rooted at the grandparent: a child created under
  # `CodeMySpec.Workspaces` recomputed `CodeMySpec` and its 101 children at
  # every vantage — 7.1s, 483 queries, 1,020 rows across ten checkouts,
  # measured 2026-09-21 — for nodes that do not read the child at all.
  #
  # Not `:project`: the project requirement a component moves is
  # `architecture_designed`, and the three component kinds are handled for
  # it — settled from the `:architecture` profile, one query and a coverage
  # pass — where a `:project` entity sent every vantage through
  # `compute_project_nodes/3`, whose delegates query for themselves and rerun
  # the orphan scan over 1,147 components: ~700ms of CPU per vantage.
  defp graph_entities({_verb, %{id: id}}), do: [{"component", id}]

  defp graph_entities(_message), do: []

  defdelegate list_components(scope), to: ComponentRepository
  defdelegate count_components(scope), to: ComponentRepository
  defdelegate list_child_components(scope, parent_component_id), to: ComponentRepository
  defdelegate list_components_with_dependencies(scope), to: ComponentRepository
  defdelegate list_components_for_coverage(scope), to: ComponentRepository
  defdelegate list_contexts(scope), to: ComponentRepository
  defdelegate list_contexts_with_dependencies(scope), to: ComponentRepository
  defdelegate list_orphaned_contexts(scope), to: ComponentRepository
  defdelegate get_component!(scope, id), to: ComponentRepository
  defdelegate get_component_by_module_name(scope, id), to: ComponentRepository
  defdelegate get_component(scope, id), to: ComponentRepository
  defdelegate list_all_descendants(scope, parent_component_id), to: ComponentRepository
  defdelegate show_architecture(scope), to: ComponentRepository
  defdelegate upsert_component(scope, attrs), to: ComponentRepository

  defdelegate search_components_by_module_name(scope, module_name_pattern),
    to: ComponentRepository

  defdelegate create_components_with_dependencies(scope, component_attrs_list, dependencies),
    to: ComponentRepository

  @doc """
  Creates a component.

  ## Examples

      iex> create_component(scope, %{field: value})
      {:ok, %Component{}}

      iex> create_component(scope, %{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  def create_component(%Scope{} = scope, attrs) do
    with {:ok, component = %Component{}} <- ComponentRepository.create_component(scope, attrs) do
      broadcast(scope, {:created, component})
      {:ok, component}
    end
  end

  @doc """
  Updates a component.

  ## Examples

      iex> update_component(scope, component, %{field: new_value})
      {:ok, %Component{}}

      iex> update_component(scope, component, %{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  def update_component(%Scope{} = scope, %Component{} = component, attrs, opts \\ []) do
    true = component.project_id == scope.active_project.id

    with {:ok, updated = %Component{}} <-
           ComponentRepository.update_component(scope, component, attrs, opts) do
      if Keyword.get(opts, :broadcast, true),
        do: broadcast(scope, {:updated, updated}, graph: structural_change?(component, updated))

      {:ok, updated}
    end
  end

  # What the graph reads off a component row: its type (the template), its
  # parent (the family and the tree edges) and its name (identity). A change
  # to anything else — a spec's prose re-synced into `description` — moves no
  # verdict and no edge, and was costing a whole family recompute at every
  # vantage: measured 2026-09-21, three prose edits under
  # `CodeMySpec.Workspaces` ran 9.8s / 923 queries each across ten checkouts,
  # because the change named its parent and the parent's family root is
  # `CodeMySpec`, 101 children.
  @structural [:type, :parent_component_id, :module_name]

  defp structural_change?(%Component{} = before, %Component{} = after_) do
    Enum.any?(@structural, &(Map.get(before, &1) != Map.get(after_, &1)))
  end

  @doc """
  Deletes a component.

  ## Examples

      iex> delete_component(scope, component)
      {:ok, %Component{}}

      iex> delete_component(scope, component)
      {:error, %Ecto.Changeset{}}

  """
  def delete_component(%Scope{} = scope, %Component{} = component) do
    true = component.project_id == scope.active_project.id

    with {:ok, component = %Component{}} <- ComponentRepository.delete_component(scope, component) do
      broadcast(scope, {:deleted, component})
      {:ok, component}
    end
  end

  @doc """
  Returns an `%Ecto.Changeset{}` for tracking component changes.

  ## Examples

      iex> change_component(scope, component)
      %Ecto.Changeset{data: %Component{}}

  """
  def change_component(%Scope{} = scope, %Component{} = component, attrs \\ %{}) do
    true = component.project_id == scope.active_project.id

    Component.changeset(component, attrs, scope)
  end

  defdelegate list_dependencies(scope), to: DependencyRepository
  defdelegate list_component_dependencies(scope, component_id), to: DependencyRepository
  defdelegate get_dependency!(scope, id), to: DependencyRepository
  defdelegate create_dependency(scope, attrs), to: DependencyRepository
  defdelegate delete_dependency(scope, dependency), to: DependencyRepository
  defdelegate validate_dependency_graph(scope), to: DependencyRepository

  @spec resolve_dependency_order(CodeMySpec.Users.Scope.t()) ::
          {:ok, [CodeMySpec.Components.Component.t()]}
  defdelegate resolve_dependency_order(scope), to: DependencyRepository

  defdelegate get_requirements_for_type(component_type), to: RequirementsRegistry

  @doc """
  Returns requirement definitions for a component based on its type, with optional filtering.

  Retrieves static requirement definitions from the Registry and applies
  filtering based on options.

  ## Options

    * `:include` - list of requirement names to include (if empty, includes all)
    * `:exclude` - list of requirement names to exclude
    * `:artifact_types` - list of artifact types to filter by (if empty, includes all)

  ## Examples

      iex> get_requirement_definitions(scope, %Component{type: "schema"}, [])
      [%RequirementDefinition{name: "spec_file", ...}, ...]

      iex> get_requirement_definitions(scope, component, include: ["spec_file", "spec_valid"])
      [%RequirementDefinition{name: "spec_file", ...}, %RequirementDefinition{name: "spec_valid", ...}]

      iex> get_requirement_definitions(scope, component, artifact_types: [:tests])
      [%RequirementDefinition{artifact_type: :tests, ...}, ...]

  """
  @spec get_requirement_definitions(Scope.t(), Component.t(), keyword()) :: [
          CodeMySpec.Requirements.RequirementDefinition.t()
        ]
  def get_requirement_definitions(_scope, %Component{type: type}, opts \\ []) do
    include_types = Keyword.get(opts, :include, [])
    exclude_types = Keyword.get(opts, :exclude, [])
    artifact_types = Keyword.get(opts, :artifact_types, [])

    RequirementsRegistry.get_requirements_for_type(type)
    |> Enum.filter(fn %{name: name, artifact_type: artifact_type} ->
      exclude = exclude_types != [] and name in exclude_types

      include =
        (include_types != [] and name in include_types) or include_types == []

      artifact_match =
        artifact_types == [] or artifact_type in artifact_types

      include && !exclude && artifact_match
    end)
  end

  @doc """
  Determines if a component is a bounded context.

  Detection logic:
  1. Primary: explicit type == "context"
  2. Fallback: module naming convention - contexts have exactly 2 parts (MyApp.ContextName)

  ## Examples

      iex> context?(%Component{type: "context"})
      true

      iex> context?(%Component{type: "repository", module_name: "MyApp.Accounts.AccountRepository"})
      false

      iex> context?(%Component{type: nil, module_name: "MyApp.Accounts"})
      true

      iex> context?(%Component{type: nil, module_name: "MyApp.Accounts.User"})
      false

  """
  @spec context?(Component.t()) :: boolean()
  def context?(%{type: "context"}), do: true
  def context?(%{type: type}) when not is_nil(type), do: false

  def context?(%{module_name: module_name}) when is_binary(module_name) do
    length(String.split(module_name, ".")) == 2
  end

  def context?(_), do: false
end
