defmodule CodeMySpec.Requirements.Invalidations do
  @moduledoc """
  The durable dirty set: what writers have said moved, and what has consumed it.

  ## The contract

  `record/4` is called by a writer that already knows what it touched.
  `pending/1` reads the marks for one project without removing them, so a
  consumer that crashes mid-recompute leaves them for the next one. `consume/1`
  removes exactly the ids it was handed, so a mark that arrived while the
  recompute was running survives to be handled on its own.

  Read-then-delete-by-id rather than a `DELETE ... RETURNING`, because the work
  between the two is a graph recompute and a write. Deleting first makes every
  crash a lost invalidation, which is the one failure this whole mechanism
  exists to make impossible.

  ## Not a batch

  A mark is consumed on its own. `pending/1` returning several is a consumer
  catching up after being down, not a window being drained — the fingerprint
  pass debounces because it is whole-project and has no cheaper option, and
  inheriting that here would spend the one advantage events have.

  ## Recording is outside the writer's transaction

  `GraphInputs.announce/2` is called from `broadcast/2`, which runs after the
  domain transaction commits. So a crash in the gap between the commit and this
  insert loses the mark, and the entity stays stale with nothing to say so.

  That gap is real and it is not closed here, because closing it means moving
  the call inside each writer's `Repo.transaction` — sixteen writers, and worth
  doing once the diff says the mechanism is otherwise sound. Until the swap the
  fingerprints are still deciding, so a lost mark costs nothing but a line in
  the diff, which is exactly the signal this phase is built to read.
  """

  import Ecto.Query, only: [from: 2]

  alias CodeMySpec.Repo
  alias CodeMySpec.Requirements.Invalidation

  @type entity :: Invalidation.entity()

  @doc """
  Mark what a writer moved.

  `entities` is what the writer names. An empty list is recorded as one
  project-wide mark rather than as nothing: a writer announced, so something
  moved, and dropping it because it could not say what would make an
  un-narrowed writer indistinguishable from a silent one.
  """
  @spec record(Ecto.UUID.t() | nil, String.t(), [entity()], String.t() | nil) :: :ok
  def record(project_id, source, entities, observation_id \\ nil)

  def record(project_id, source, entities, observation_id) when is_binary(project_id) do
    if enabled?(), do: do_record(project_id, source, entities, observation_id)

    :ok
  end

  def record(_no_project, _source, _entities, _observation_id), do: :ok

  @doc """
  Whether marks are being recorded at all.

  This adds an insert to the path of every domain write, for a mechanism that
  is not yet deciding anything. A flag rather than a deploy is how that gets
  turned off if it costs more than it measures — and it is the same switch the
  swap flips, in the other direction.
  """
  @spec enabled?() :: boolean()
  def enabled?, do: Application.get_env(:code_my_spec, :graph_invalidations, true)

  defp do_record(project_id, source, entities, observation_id) do
    now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

    rows =
      entities
      |> normalize()
      |> Enum.map(fn entity ->
        entity
        |> columns()
        |> Map.merge(%{
          project_id: project_id,
          source: source,
          observation_id: observation_id,
          inserted_at: now
        })
      end)

    Repo.insert_all(Invalidation, rows)
  end

  @doc "Marks this project has accumulated, oldest first, left in place."
  @spec pending(Ecto.UUID.t()) :: [Invalidation.t()]
  def pending(project_id) when is_binary(project_id) do
    Repo.all(
      from(i in Invalidation,
        where: i.project_id == ^project_id,
        order_by: [asc: i.id]
      )
    )
  end

  @doc "Drop exactly these marks, leaving anything that arrived since."
  @spec consume([Invalidation.t()] | [integer()]) :: :ok
  def consume([]), do: :ok

  def consume(marks) do
    ids = Enum.map(marks, &mark_id/1)

    Repo.delete_all(from(i in Invalidation, where: i.id in ^ids))

    :ok
  end

  @doc """
  The entities these marks name, and whether any of them named nothing.

  Separated because the two answers are consumed differently: a set of entities
  is work to do, and a project-wide mark means the set is not trustworthy as a
  complete account of what moved.
  """
  @spec entities([Invalidation.t()]) :: {MapSet.t(entity()), boolean()}
  def entities(marks) do
    Enum.reduce(marks, {MapSet.new(), false}, fn mark, {named, wide?} ->
      case Invalidation.entity(mark) do
        :project -> {named, true}
        entity -> {MapSet.put(named, entity), wide?}
      end
    end)
  end

  defp mark_id(%Invalidation{id: id}), do: id
  defp mark_id(id) when is_integer(id), do: id

  # A writer that named nothing still moved something.
  defp normalize([]), do: [:project]
  defp normalize(entities), do: Enum.uniq(entities)

  defp columns({"component", id}), do: %{component_id: id, story_id: nil}
  defp columns({"story", id}), do: %{component_id: nil, story_id: id}
  defp columns(:project), do: %{component_id: nil, story_id: nil}
end
