defmodule CodeMySpec.Requirements.Shadow do
  @moduledoc """
  The event-derived projection, and how far it is from the real one.

  `shadow_requirements` mirrors `requirements` column for column, so the same
  nodes land the same way and a difference between the two tables is a
  difference in the *decision* that produced them — which is the only variable
  under test. Everything downstream of that decision is shared.

  ## What the diff means, and which direction is fatal

  Three numbers, and they are not equally bad:

    * `missing` — the live projection has a row the shadow does not. The event
      path never computed that entity, so a writer owes a mark. This is the
      direction that must reach zero: in production it is a requirement nobody
      revisits, which costs an agent a session.

    * `extra` — the shadow has a row the live projection does not. Usually the
      shadow computed an entity the live pass had no reason to, which costs a
      recompute and nothing else.

    * `disagree` — both have the row and the verdicts differ. The expensive one
      to read, because it is either a stale shadow row (a missed mark, same as
      `missing`) or a genuine computation difference, and the sample is what
      tells them apart.

  A run of passes at `missing: 0, disagree: 0` is what earns the swap.

  ## What the diff cannot see

  It proves *coverage*, not *narrowness*. A writer that names nothing records a
  project-wide mark, the projector reads that as "any of it" and recomputes
  every entity, and the diff agrees — exactly as it would for a writer that
  named its entities precisely. Verified by turning `Invalidations` off
  entirely, which is the only thing that makes the comparison fail: a story
  created after the seed came back as three `missing` rows, named.

  So this number answers "would the event path have missed something", and the
  cost question — how often a project-wide mark drags the whole project through
  a recompute that a narrowed writer would have avoided — is a different
  measurement, taken from how often those marks fire. Reading agreement as
  evidence of narrowness is the mistake this paragraph exists to prevent.

  ## Why the diff is not per event

  Writing is per entity and per event — that is the point. Comparing is not:
  it reads both projections whole, so doing it per event would cost more than
  the thing it measures. It runs on the fingerprint pass, which is already
  loading the context and is exactly the moment the two systems can be asked
  the same question.
  """

  import Ecto.Query, only: [from: 2, where: 2, dynamic: 2]

  require Logger

  alias CodeMySpec.Components.Component
  alias CodeMySpec.Repo
  alias CodeMySpec.Requirements.Node
  alias CodeMySpec.Requirements.Projection
  alias CodeMySpec.Stories.Story
  alias CodeMySpec.Users.Scope

  @source {"shadow_requirements", Node}

  @type entity :: {String.t(), term()}

  @type report :: %{
          missing: non_neg_integer(),
          extra: non_neg_integer(),
          disagree: non_neg_integer(),
          live: non_neg_integer(),
          shadow: non_neg_integer(),
          sample: [String.t()]
        }

  @doc """
  Whether the shadow projection is being maintained.

  Separate from `Invalidations.enabled?/0`: recording marks is cheap and useful
  on its own, where maintaining a second projection is the expensive half. Off
  turns the experiment off without losing the marks that would let it restart.
  """
  @spec enabled?() :: boolean()
  def enabled?, do: Application.get_env(:code_my_spec, :graph_shadow_projection, false)

  @doc """
  Replace one entity's shadow rows for this vantage.

  Delete-then-insert rather than the live path's upsert-then-reap. The live
  writer has to handle a whole graph at once and reap what it did not produce;
  this only ever holds one entity, so "these are the rows" is the whole
  statement and the narrower operation is the honest one.

  An entity that computes to no nodes still deletes — that is a real answer
  (a component whose template is empty under this config) and leaving the old
  rows would make the shadow permanently over-count.
  """
  @spec write(Scope.t(), entity(), [map()]) :: :ok
  def write(%Scope{} = scope, {entity_type, entity_id}, nodes) do
    working_copy_id = Projection.vantage(scope)
    now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

    Repo.transaction(fn ->
      @source
      |> where(^owner_filter(entity_type, entity_id))
      |> where(^copy_filter(working_copy_id))
      |> Repo.delete_all()

      case Enum.map(nodes, &row(&1, entity_type, entity_id, working_copy_id, now)) do
        [] -> :ok
        rows -> Repo.insert_all(@source, rows)
      end
    end)

    :ok
  end

  @doc """
  How far the shadow is from the live projection, for this reader's vantage.

  Scoped through the project's entity ids the same way `Projection.load/2`
  scopes its own read, so the two sides are asked about the same population.

  Reads those ids itself rather than taking a context, which is what lets this
  be called from the write path after a pass rather than from inside one. Two
  id queries against a context that is already loaded would be waste; against a
  caller that has none, they are the difference between this being callable and
  not.
  """
  @spec diff(Scope.t()) :: report()
  def diff(%Scope{active_project_id: project_id} = scope) when is_binary(project_id) do
    working_copy_id = Projection.vantage(scope)
    {component_ids, story_ids} = entity_ids(project_id)

    live = verdicts(Node, project_id, component_ids, story_ids, working_copy_id)
    shadow = verdicts(@source, project_id, component_ids, story_ids, working_copy_id)

    live_keys = MapSet.new(Map.keys(live))
    shadow_keys = MapSet.new(Map.keys(shadow))

    missing = MapSet.difference(live_keys, shadow_keys)
    extra = MapSet.difference(shadow_keys, live_keys)

    disagree =
      live_keys
      |> MapSet.intersection(shadow_keys)
      |> Enum.filter(&(Map.fetch!(live, &1) != Map.fetch!(shadow, &1)))

    %{
      missing: MapSet.size(missing),
      extra: MapSet.size(extra),
      disagree: length(disagree),
      live: map_size(live),
      shadow: map_size(shadow),
      sample: sample(missing, extra, disagree)
    }
  end

  def diff(%Scope{}), do: empty_report()

  @doc """
  Say where the shadow stands, on the pass that measured it.

  One line, in the shape the other `[Requirements]` lines take, because this
  number is read against them — a diff is only meaningful beside the pass that
  produced it.
  """
  @spec log(report()) :: :ok
  def log(%{live: 0, shadow: 0}), do: :ok

  def log(report) do
    verdict = if report.missing == 0 and report.disagree == 0, do: "agrees", else: "differs"

    Logger.info(
      "[Requirements] shadow #{verdict} — missing #{report.missing}, " <>
        "extra #{report.extra}, disagree #{report.disagree} " <>
        "(live #{report.live}, shadow #{report.shadow})" <> sample_suffix(report.sample)
    )
  end

  @doc "Forget the shadow projection for this vantage, so it rebuilds from scratch."
  @spec clear(Scope.t()) :: :ok
  def clear(%Scope{active_project_id: project_id} = scope) when is_binary(project_id) do
    {component_ids, story_ids} = entity_ids(project_id)

    @source
    |> scoped(project_id, component_ids, story_ids)
    |> where(^copy_filter(Projection.vantage(scope)))
    |> Repo.delete_all()

    :ok
  end

  def clear(%Scope{}), do: :ok

  # The project's entities, for scoping both sides of a comparison the way
  # `Projection.project_rows/3` scopes its own read. Ids rather than a context
  # because neither caller has one.
  defp entity_ids(project_id) do
    {Repo.all(from(c in Component, where: c.project_id == ^project_id, select: c.id)),
     Repo.all(from(s in Story, where: s.project_id == ^project_id, select: s.id))}
  end

  # `{owner, name} => satisfied`, which is the whole of what a projection
  # claims. Everything else on a row is rehydrated from the registry at read
  # time — `Node`'s own moduledoc says a row is "identity plus verdict" — so
  # comparing more would be comparing the registry against itself.
  defp verdicts(source, project_id, component_ids, story_ids, working_copy_id) do
    source
    |> scoped(project_id, component_ids, story_ids)
    |> where(^copy_filter(working_copy_id))
    |> select_verdicts()
    |> Repo.all()
    |> Map.new(fn {component_id, story_id, proj_id, name, satisfied} ->
      {{component_id, story_id, proj_id, name}, satisfied}
    end)
  end

  defp select_verdicts(query) do
    from(n in query, select: {n.component_id, n.story_id, n.project_id, n.name, n.satisfied})
  end

  defp scoped(source, project_id, component_ids, story_ids) do
    from(n in source,
      where:
        n.component_id in ^component_ids or n.story_id in ^story_ids or
          n.project_id == ^project_id
    )
  end

  defp owner_filter("component", id), do: dynamic([n], n.component_id == ^id)
  defp owner_filter("story", id), do: dynamic([n], n.story_id == ^id)
  defp owner_filter("project", id), do: dynamic([n], n.project_id == ^id)

  # `is_nil` rather than `== nil`, for the reason `Projection.copy_filter/1`
  # gives: `= NULL` is never true, so the unscoped vantage would match no row
  # and every comparison would report the whole projection missing.
  defp copy_filter(nil), do: dynamic([n], is_nil(n.working_copy_id))
  defp copy_filter(id), do: dynamic([n], n.working_copy_id == ^id)

  defp row(node, entity_type, entity_id, working_copy_id, now) do
    %{
      name: node.name,
      description: node.description || node.name,
      satisfied: node.satisfied,
      details: node.details || %{},
      checked_at: now,
      inputs_fingerprint: Map.get(node, :inputs_fingerprint),
      owner_component_type: Map.get(node, :owner_component_type),
      node_scope: node |> Map.get(:node_scope) |> scope_string(),
      inserted_at: now,
      updated_at: now,
      working_copy_id: working_copy_id
    }
    |> Map.put(owner_field(entity_type), entity_id)
  end

  defp owner_field("component"), do: :component_id
  defp owner_field("story"), do: :story_id
  defp owner_field("project"), do: :project_id

  defp scope_string(nil), do: nil
  defp scope_string(scope) when is_atom(scope), do: Atom.to_string(scope)
  defp scope_string(scope) when is_binary(scope), do: scope

  # A handful, named, because the counts say how wrong and never say where —
  # which is the gap `why_all/5` had to be added to close on the fingerprint
  # side. Three of each is enough to point at the writer that owes a mark.
  defp sample(missing, extra, disagree) do
    Enum.concat([
      missing |> Enum.take(3) |> Enum.map(&"missing #{key_label(&1)}"),
      extra |> Enum.take(3) |> Enum.map(&"extra #{key_label(&1)}"),
      disagree |> Enum.take(3) |> Enum.map(&"disagree #{key_label(&1)}")
    ])
  end

  defp key_label({component_id, story_id, project_id, name}) do
    owner =
      cond do
        component_id -> "component:#{String.slice(component_id, 0, 8)}"
        story_id -> "story:#{story_id}"
        project_id -> "project"
        true -> "?"
      end

    "#{owner}/#{name}"
  end

  defp sample_suffix([]), do: ""
  defp sample_suffix(sample), do: "; " <> Enum.join(sample, ", ")

  defp empty_report,
    do: %{missing: 0, extra: 0, disagree: 0, live: 0, shadow: 0, sample: []}
end
