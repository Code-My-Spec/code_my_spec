defmodule CodeMySpec.AcceptanceCriteria.AcceptanceCriteriaRepository do
  @moduledoc """
  Direct-DB implementation of the AcceptanceCriteria interface.
  """

  import Ecto.Query, warn: false

  alias CodeMySpec.AcceptanceCriteria.Criterion
  alias CodeMySpec.Repo
  alias CodeMySpec.Stories.Story
  alias CodeMySpec.Users.Scope

  require Logger

  @doc """
  Record where each criterion's spex file lives, for criteria that do not
  already say.

  The convention writes the association into a filename —
  `criterion_<id>_<slug>_spex.exs` — and the scan reads the ids back out of it,
  so the link is derived in two directions from four things that all move. When
  they stop agreeing the symptom is silent: a criterion whose file cannot be
  matched reads as work not done, and coverage that exists stops counting.

  Reconciling one project measured the cost: 841 spex files against 921
  criteria, 97 unmatched purely because ids had been renumbered and files never
  renamed. 73 recovered by slug, 5 by similarity, 2 by hand.

  Claiming on sight turns the filename into a name rather than an identifier.
  Only criteria with no recorded path are touched, so a file that is later
  renamed keeps pointing where it was recorded rather than being re-derived —
  which is the whole point.
  """
  @spec claim_spec_paths(Scope.t(), %{integer() => String.t()}) :: {:ok, non_neg_integer()}
  def claim_spec_paths(_scope, paths) when map_size(paths) == 0, do: {:ok, 0}

  def claim_spec_paths(%Scope{active_project_id: project_id}, paths) do
    ids = Map.keys(paths)

    # Unclaimed, plus claimed-but-stale.
    #
    # It only ever filled empties, on the reasoning that a recorded path is a
    # decision and a scan should not overrule it. True while a file keeps its
    # name — and a spex gets renamed whenever its criterion is reworded, which
    # is the normal way a criterion changes. The record then points at a
    # filename nobody will create again, `bdd_specs_exist` reads the record,
    # finds nothing, and reports a spec that is sitting right there in the same
    # directory. Silently, because a missing file is a legitimate answer.
    #
    # Overruling is safe here in a way it would not be generally: the id comes
    # from the observed filename, so a row is only rewritten when a file
    # claiming to be that criterion's spec is on disk *and* the path it holds
    # is not. Nothing is taken from a record that still resolves.
    candidates =
      from(c in Criterion,
        where: c.project_id == ^project_id and c.id in ^ids,
        select: {c.id, c.spec_path}
      )
      |> Repo.all()

    claimable =
      Enum.filter(candidates, fn
        {_id, path} when is_nil(path) or path == "" -> true
        {_id, path} -> not File.exists?(path)
      end)

    count =
      Enum.reduce(claimable, 0, fn {id, previous}, acc ->
        recorded = Map.fetch!(paths, id)

        {n, _} =
          from(c in Criterion, where: c.id == ^id and c.project_id == ^project_id)
          |> Repo.update_all(set: [spec_path: recorded, updated_at: DateTime.utc_now()])

        log_repair(id, previous, recorded)

        acc + n
      end)

    {:ok, count}
  end

  # A repair is worth a line; a first claim is not. The two are different
  # events -- one records something new, the other corrects a record that was
  # wrong -- and only the second says anything about a file having moved out
  # from under the project.
  defp log_repair(_id, previous, _recorded) when is_nil(previous) or previous == "", do: :ok

  defp log_repair(id, previous, recorded) do
    Logger.info(
      "[AcceptanceCriteria] criterion #{id} pointed at #{previous}, which is gone; " <>
        "repointed at #{recorded}, found on disk carrying the same criterion id"
    )
  end

  @doc """
  Every claimed spec path in the project, mapped to the story that owns it.

  The counterpart to `claim_spec_paths/2`: that records which file a criterion
  is checked by, this reads it back. Anything deciding what a spex failure
  belongs to should ask here rather than parse the filename — the leading number
  in `test/spex/<n>_.../` is a directory name, not a story id, and the two have
  drifted apart.
  """
  @spec spec_path_story_ids(Scope.t()) :: %{String.t() => integer()}
  def spec_path_story_ids(%Scope{active_project_id: project_id}) do
    from(c in Criterion,
      where: c.project_id == ^project_id,
      where: not is_nil(c.spec_path) and c.spec_path != "",
      select: {c.spec_path, c.story_id}
    )
    |> Repo.all()
    |> Map.new()
  end

  @spec list_story_criteria(Scope.t(), integer()) :: [Criterion.t()]
  def list_story_criteria(%Scope{active_project: %{id: project_id}}, story_id) do
    from(c in Criterion,
      where: c.story_id == ^story_id and c.project_id == ^project_id,
      order_by: [asc: c.inserted_at]
    )
    |> Repo.all()
  end

  @spec get_criterion!(Scope.t(), integer()) :: Criterion.t()
  def get_criterion!(%Scope{active_project: %{id: project_id}}, id) do
    Repo.get_by!(Criterion, id: id, project_id: project_id)
  end

  @spec get_criterion(Scope.t(), integer()) :: Criterion.t() | nil
  def get_criterion(%Scope{active_project: %{id: project_id}}, id) do
    Repo.get_by(Criterion, id: id, project_id: project_id)
  end

  @spec create_criterion(Scope.t(), Story.t(), map()) ::
          {:ok, Criterion.t()} | {:error, Ecto.Changeset.t() | :cross_project}
  def create_criterion(%Scope{active_project: %{id: project_id}}, %Story{} = story, attrs) do
    if story.project_id == project_id do
      attrs =
        attrs
        |> Map.put(:story_id, story.id)
        |> Map.put(:project_id, project_id)

      %Criterion{}
      |> Criterion.changeset(attrs)
      |> Repo.insert()
    else
      {:error, :cross_project}
    end
  end

  @spec update_criterion(Scope.t(), Criterion.t(), map()) ::
          {:ok, Criterion.t()} | {:error, Ecto.Changeset.t() | :cross_project}
  def update_criterion(
        %Scope{active_project: %{id: project_id}},
        %Criterion{project_id: cp_id} = criterion,
        attrs
      ) do
    if cp_id == project_id do
      criterion
      |> Criterion.changeset(attrs)
      |> Repo.update()
    else
      {:error, :cross_project}
    end
  end

  @spec delete_criterion(Scope.t(), Criterion.t()) ::
          {:ok, Criterion.t()} | {:error, Ecto.Changeset.t() | :cross_project}
  def delete_criterion(
        %Scope{active_project: %{id: project_id}},
        %Criterion{
          project_id: cp_id
        } = criterion
      ) do
    if cp_id == project_id do
      Repo.delete(criterion)
    else
      {:error, :cross_project}
    end
  end

  @spec mark_verified(Scope.t(), Criterion.t()) ::
          {:ok, Criterion.t()} | {:error, Ecto.Changeset.t() | :cross_project}
  def mark_verified(%Scope{} = scope, %Criterion{} = criterion) do
    update_criterion(scope, criterion, %{
      verified: true,
      verified_at: DateTime.utc_now()
    })
  end

  @spec mark_unverified(Scope.t(), Criterion.t()) ::
          {:ok, Criterion.t()} | {:error, Ecto.Changeset.t() | :cross_project}
  def mark_unverified(%Scope{} = scope, %Criterion{} = criterion) do
    update_criterion(scope, criterion, %{
      verified: false,
      verified_at: nil
    })
  end
end
