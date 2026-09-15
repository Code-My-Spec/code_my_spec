defmodule CodeMySpec.Requirements.Projection do
  @moduledoc """
  Reads the requirement graph back out of rows.

  The counterpart to `NodeRepository`, and the thing that decides whether rows
  can replace `requirement_graphs.payload`. If a graph read from rows differs
  from the one just computed, the rows are not carrying the graph and no reader
  should be moved onto them.

  ## What is stored and what is rehydrated

  A row holds identity and verdict — `satisfied`, `details`, and which entity it
  belongs to. Everything else on a node comes back from the
  `RequirementDefinition` by name (`scope`, `execution_type`, `validation_type`,
  `orchestrated_by`, `role`, `satisfied_by`, `render_command_always?`,
  `prerequisites`) or from the entity (`entity_name`).

  That split is deliberate. Persisting the definition fields would keep a second
  copy of the definition table in every row, and the copy would be the stale one
  the day a definition changes — a rename would need a backfill, and until it ran
  the graph would describe requirements that no longer exist under names nobody
  uses.

  ## Nodes this projection cannot rehydrate

  A row whose `name` matches no definition for its entity type is dropped rather
  than guessed at. It means the definitions moved and the rows have not caught
  up, which is a real condition — the old node genuinely is not in the graph any
  more — and inventing a node from a row would put it back.
  """

  import Ecto.Query

  alias CodeMySpec.Files.File
  alias CodeMySpec.Repo
  alias CodeMySpec.Requirements.{Edge, Node, Registry, Requirement}
  alias CodeMySpec.Users.Scope

  @doc """
  Every vantage this project already has rows in, `nil` among them.

  What a write path needs in order to maintain what the read paths ask for.
  Rows are keyed per working copy, so a pass that computes one vantage leaves
  every other one exactly as it was — and `GraphWatcher` is per *project* and
  holds a single scope, so it was maintaining whichever checkout happened to
  start it and no others.

  Measured on story 1063's spex: the watcher wrote 14 rows at
  `12cb6e42-…` while every HTTP read asked the `nil` row-space and got nothing.
  Invisible until reads stopped recomputing, because an unscoped reader used to
  find no rows, rebuild them itself and serve a correct answer — paying a full
  recompute on every read to cover a write path that was never maintaining its
  row-space at all.

  `nil` is always included: it is what every reader that is not an agent
  resolves to, so it is never not wanted.

  Vantages with no rows yet are not invented here. A checkout nobody has
  computed for has nothing to keep up to date — the reader that cares says so
  by settling, and `GraphWatcher` folds the vantage it asked from into the
  pass.

  Asked of the project-owned rows only, which is exact rather than approximate:
  a row has exactly one owner of the three, and every pass recomputes the
  project-level nodes unconditionally — `recompute_stale/3` drops
  `entity_type == "project"` from what it keeps and rebuilds it. So a vantage
  that has been computed at all has project rows, and a vantage with no project
  rows has none of any kind.
  """
  @spec vantages(Scope.t()) :: [Ecto.UUID.t() | nil]
  def vantages(%Scope{active_project_id: project_id} = scope) when is_binary(project_id) do
    stored =
      Node
      |> where([n], n.project_id == ^project_id)
      |> distinct(true)
      |> select([n], n.working_copy_id)
      |> Repo.all()

    live_vantages(scope, stored)
  end

  def vantages(%Scope{}), do: [nil]

  @doc """
  The vantages worth computing, out of `nil`, the stored ones, and any a reader
  has asked for.

  Filters to checkouts that still exist, which is not tidiness: `GraphCache.publish/4`
  writes a `requirement_graphs` row keyed on the copy, and the foreign key
  refuses one that is gone. A watcher holding a since-deleted vantage — from
  its own rows, or from a reader that named it before the offboard — turns
  every subsequent pass into a logged fault on a project that is otherwise
  fine.

  The orphaned rows are left alone. Reaping them is a separate decision with a
  failure mode of its own — issue `e53fc5ad` is about exactly that cleanup and
  says not to improvise it — and a vantage nobody computes for costs only disk.
  """
  @spec live_vantages(Scope.t(), Enumerable.t()) :: [Ecto.UUID.t() | nil]
  def live_vantages(%Scope{active_project_id: project_id}, candidates)
      when is_binary(project_id) do
    candidates
    |> Enum.uniq()
    |> Enum.filter(&live_copy?(project_id, &1))
    |> then(&Enum.uniq([nil | &1]))
  end

  def live_vantages(%Scope{}, _candidates), do: [nil]

  # A checkout that has been offboarded leaves its rows behind, and computing
  # for it raises rather than wasting work: `GraphCache.publish/4` writes a
  # `requirement_graphs` row keyed on the copy, and the foreign key refuses a
  # copy that is gone. The watcher logs that at `:error` — so an offboard would
  # turn every subsequent pass into a reported fault, forever, on a project
  # that is otherwise fine.
  #
  # Caught by criterion 2867, which deletes a copy and then expects the graph
  # to carry on: `insert or update on table "requirement_graphs" violates
  # foreign key constraint`.
  #
  # The orphaned rows are left alone here. Reaping them is a separate decision
  # with a real failure mode of its own — issue `e53fc5ad` is about exactly
  # that cleanup and says not to improvise it — and a vantage nobody computes
  # for costs nothing but disk.
  defp live_copy?(_project_id, nil), do: true

  defp live_copy?(project_id, working_copy_id) do
    Repo.exists?(
      from(c in "working_copies",
        where:
          c.id == type(^working_copy_id, :binary_id) and
            c.project_id == type(^project_id, :binary_id)
      )
    )
  end

  @doc """
  The graph as `{nodes, edges}`, in the same shape `compute_graph/1` returns.
  """
  @spec load(Scope.t(), map()) :: {[Requirement.t()], [map()]}
  def load(%Scope{active_project_id: project_id} = scope, ctx) do
    rows = project_rows(project_id, vantage(scope), ctx)
    nodes = rows |> Enum.map(&rehydrate(&1, ctx)) |> Enum.reject(&is_nil/1)

    by_id = Map.new(rows, &{&1.id, &1})
    {nodes, edges_for(rows, by_id, ctx)}
  end

  @doc """
  Whose view of the project this read is.

  Satisfaction is stored per working copy because that is what it has always
  been — `Preloader.load/1` scopes its file query to one checkout, so every
  verdict is a statement about what that checkout could see. Reading therefore
  has to name a checkout too, and a reader that does not gets one row per copy
  per node with `Map.new/2` keeping whichever came last.

  An agent reads as itself: it must not be told a spec exists because some other
  worktree has one, which is the over-satisfaction `Preloader`'s moduledoc
  measured at 303 skipped specs.

  Anything that is not a checkout reads as the project's **default working
  copy** — in practice the main checkout, the one being pushed to while agents
  work in worktrees off it. That makes it the main-branch view without anything
  having to fetch main, and it is a tree that actually existed, which a union of
  checkouts is not.

  A project that has named no default falls back to the unscoped row. That row
  is the blended computation and it over-satisfies; it is the honest answer to
  "you have not told me which checkout speaks for this project" and is visible
  as soon as anyone looks.
  """
  @spec vantage(Scope.t()) :: Ecto.UUID.t() | nil
  def vantage(%Scope{active_working_copy_id: working_copy_id}) when is_binary(working_copy_id),
    do: working_copy_id

  # A reader that names no checkout gets the **unscoped** row-space, not the
  # default checkout's.
  #
  # This used to resolve to `project.default_working_copy_id` so that a UI
  # publish could be found again (`cc4745dc`). Reads go through this same
  # function, so nil-writes and nil-reads find each other equally well — and
  # resolving here put a graph that is *not* that checkout's answer into that
  # checkout's rows.
  #
  # `GraphCache.publish/3` keys its row on `scope.active_working_copy_id`, the
  # raw field, so the two layers disagreed about identity: separate cache rows,
  # shared projection rows. An unscoped publish counted its own nodes, an agent
  # then rewrote the rows under it with its narrower view, and the next unscoped
  # read found fewer rows than its cache row claimed. `served_graph/3` refused
  # the shortfall — correctly — and recomputed. Every time.
  #
  # Measured on this project before the change: 348 full computes in one log,
  # median 2.6s, p90 5.9s, max 14.8s, 116 of them from stop hooks.
  #
  # Which checkout's *files* an unscoped reader is shown is a separate question,
  # answered by `Preloader.files_vantage/1`. That one resolves; this one does
  # not, and they are different questions: whose files am I describing, versus
  # whose answer is this.
  def vantage(%Scope{}), do: nil

  @doc """
  Which requirements a file bears on.

  The question the blob could not answer, and the reason the graph became rows:
  a `bytea` addressed by one hash has no way to say which of its 5,000 nodes a
  changed file touches, so any change meant discarding the whole payload.

  A file records its owner — `component_id` or `story_id` — and so does a
  requirement, so this is one join. It returns rows rather than rehydrated
  nodes: the caller asking "what does this file affect" wants the set, and
  rehydration costs a definition lookup per node for fields it did not ask for.

  A file owned by nothing — unclassified, or project-level — bears on nothing,
  which is the honest answer rather than "every project requirement".
  """
  @spec for_file(Scope.t(), String.t()) :: [Node.t()]
  def for_file(%Scope{active_project_id: project_id}, path) do
    File
    |> where([f], f.project_id == ^project_id and f.path == ^path)
    |> select([f], {f.component_id, f.story_id})
    |> Repo.one()
    |> case do
      nil -> []
      {nil, nil} -> []
      {component_id, story_id} -> nodes_owned_by(component_id, story_id)
    end
  end

  # One clause per owner rather than an `or` across both. Ecto refuses
  # `field == ^nil` outright — it would mean `= NULL`, never true — and a file
  # has exactly one owner, so the shape of the data is two clauses.
  defp nodes_owned_by(component_id, nil) do
    Node |> where([n], n.component_id == ^component_id) |> Repo.all()
  end

  defp nodes_owned_by(nil, story_id) do
    Node |> where([n], n.story_id == ^story_id) |> Repo.all()
  end

  # A file claimed by both would be a sync bug, and answering with the union
  # would hide it. Neither is reachable through `for_file/2`, which returns
  # early on `{nil, nil}`.
  defp nodes_owned_by(component_id, story_id) do
    Node
    |> where([n], n.component_id == ^component_id or n.story_id == ^story_id)
    |> Repo.all()
  end

  # Only rows belonging to entities this project currently has. A component
  # deleted without its rows going with it would otherwise reappear as a node,
  # and `on_delete: :delete_all` covers the referential half but not a row whose
  # component id was nulled.
  defp project_rows(project_id, working_copy_id, ctx) do
    component_ids = Enum.map(ctx.components, & &1.id)
    story_ids = Enum.map(ctx.stories, & &1.id)

    Node
    |> where(
      [n],
      n.component_id in ^component_ids or n.story_id in ^story_ids or
        n.project_id == ^project_id
    )
    |> where(^copy_filter(working_copy_id))
    |> Repo.all()
  end

  # `is_nil` rather than `== nil`. `= NULL` is never true in SQL, so a project
  # with no default working copy would match no row and read as a graph with no
  # nodes — "you have not chosen a vantage point" arriving as "this project has
  # no requirements".
  defp copy_filter(nil), do: dynamic([n], is_nil(n.working_copy_id))
  defp copy_filter(id), do: dynamic([n], n.working_copy_id == ^id)

  defp rehydrate(row, ctx) do
    with {:ok, entity_type, entity} <- entity_for(row, ctx),
         %{} = definition <- definition_for(row, entity, row.name) do
      %Requirement{
        entity_type: entity_type,
        entity_id: entity_id(row, entity_type),
        entity_name: entity_name(entity),
        name: row.name,
        description: definition.description,
        satisfied: row.satisfied,
        satisfied_by: definition.satisfied_by,
        scope: definition.scope || :local,
        execution_type: definition.execution_type || :main_agent,
        validation_type: definition.validation_type || :automatic,
        prerequisites: definition.prerequisites || [],
        orchestrated_by: definition.orchestrated_by,
        render_command_always?: definition.render_command_always? || false,
        role: definition.role,
        details: row.details || %{},
        checked_at: row.checked_at,
        inputs_fingerprint: row.inputs_fingerprint
      }
      |> with_parent(entity_type, entity, definition, ctx)
    else
      _ -> nil
    end
  end

  # Who orchestrates this node, restored the same way `entity_name` is —
  # derived from the entity and the context rather than stored.
  #
  # It was not restored at all, so a served graph reported every orchestrated
  # requirement under `## unknown`: `RequirementsMapper` groups a wave by
  # `parent_entity_name` and falls back to that word when it is nil. Invisible
  # while reads recomputed, because a computed node carries it — four of story
  # 561's and 563's criteria are about which context a wave belongs to, and
  # they read "unknown" for all of them.
  #
  # Derived rather than persisted for the reason the moduledoc gives about
  # definition fields: a stored copy is the stale one the day a context is
  # renamed.
  # Mirrors `RequirementGraph.build_node/5` exactly, which is the point: a child
  # takes its explicit parent, and a parent- or self-scope node *self-parents
  # when orchestrated*, so it groups under its own context header rather than
  # floating above the wave it belongs to.
  #
  # Getting only the first half right leaves a context's own `review_file`
  # under `## unknown` while its children sit under the context — which reads
  # as two waves and is what criteria 5628, 5815, 5903 and 5574 are about.
  defp with_parent(%Requirement{} = req, "component", component, definition, ctx) do
    cond do
      parent = Map.get(ctx.components_by_id, Map.get(component, :parent_component_id)) ->
        %{req | parent_entity_id: parent.id, parent_entity_name: parent.module_name}

      definition.orchestrated_by ->
        %{req | parent_entity_id: component.id, parent_entity_name: component.module_name}

      true ->
        req
    end
  end

  defp with_parent(req, _type, _entity, _definition, _ctx), do: req

  defp entity_for(%Node{component_id: id}, ctx) when not is_nil(id) do
    case Map.get(ctx.components_by_id, id) do
      nil -> :error
      component -> {:ok, "component", component}
    end
  end

  defp entity_for(%Node{story_id: id}, ctx) when not is_nil(id) do
    case Enum.find(ctx.stories, &(&1.id == id)) do
      nil -> :error
      story -> {:ok, "story", story}
    end
  end

  defp entity_for(%Node{project_id: id}, _ctx) when not is_nil(id),
    do: {:ok, "project", %CodeMySpec.Projects.Project{id: id}}

  defp entity_for(_row, _ctx), do: :error

  # The row says which definition produced it, because the name alone does not.
  #
  # Six names — `spec_file`, `spec_valid`, `test_file`, `test_spec_alignment`,
  # `implementation_file`, `tests_passing` — exist as a `:child` def on a parent
  # template *and* as a `:self` def on the child type's own. They differ in
  # `orchestrated_by`, which is what groups an orchestrated wave under its
  # context header, so picking the wrong one renders the wave with no header at
  # all. Computing instantiates the parent's template; reading used to look up
  # the child's own and quietly get the other definition.
  #
  # `nil` columns mean a row written before they existed. Inferring from the
  # entity's own type is what that row was already getting, and the next pass
  # over its vantage rewrites it with the columns set — so the fallback drains
  # rather than becoming the permanent path.
  defp definition_for(row, entity, name) do
    stored_definition(row, name) || own_definition(entity, name)
  end

  defp stored_definition(%Node{owner_component_type: type, node_scope: scope}, name)
       when is_binary(type) and is_binary(scope) do
    type
    |> Registry.get_requirements_for_type()
    |> Enum.find(&(&1.name == name and to_string(&1.node_scope) == scope))
  end

  defp stored_definition(_row, _name), do: nil

  defp own_definition(entity, name) do
    entity
    |> Registry.get_requirements()
    |> Enum.find(&(&1.name == name))
  end

  defp entity_id(row, "component"), do: row.component_id
  defp entity_id(row, "story"), do: row.story_id
  defp entity_id(row, "project"), do: row.project_id

  defp entity_name(%{title: title}) when is_binary(title), do: title
  defp entity_name(%{module_name: name}) when is_binary(name), do: name
  defp entity_name(%{name: name}) when is_binary(name), do: name
  defp entity_name(_entity), do: nil

  # An edge is only in the graph if both its nodes rehydrated. One that lost an
  # end is an edge to a node the definitions no longer describe, and keeping it
  # would gate a node on something unreachable.
  defp edges_for(rows, by_id, ctx) do
    keys = Map.new(rows, &{&1.id, node_key(&1, ctx)})
    ids = Map.keys(by_id)

    Edge
    |> where([e], e.from_requirement_id in ^ids and e.to_requirement_id in ^ids)
    |> Repo.all()
    |> Enum.flat_map(fn edge ->
      case {Map.get(keys, edge.from_requirement_id), Map.get(keys, edge.to_requirement_id)} do
        {nil, _} -> []
        {_, nil} -> []
        {from, to} -> [%{from: from, to: to}]
      end
    end)
  end

  defp node_key(row, ctx) do
    case entity_for(row, ctx) do
      {:ok, entity_type, _entity} -> {entity_type, entity_id(row, entity_type), row.name}
      :error -> nil
    end
  end
end
