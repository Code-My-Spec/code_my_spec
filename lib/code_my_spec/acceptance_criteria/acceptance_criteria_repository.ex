defmodule CodeMySpec.AcceptanceCriteria.AcceptanceCriteriaRepository do
  @moduledoc """
  Direct-DB implementation of the AcceptanceCriteria interface.
  """

  import Ecto.Query, warn: false

  alias CodeMySpec.AcceptanceCriteria.Criterion
  alias CodeMySpec.Files
  alias CodeMySpec.Repo
  alias CodeMySpec.Stories
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

  def claim_spec_paths(%Scope{active_project_id: project_id} = scope, paths) do
    ids = Map.keys(paths)

    # Which files this checkout actually has.
    #
    # Read once, here, rather than asked per path — and read from the record
    # rather than the disk. See `stale?/2`.
    present = present_paths(scope, paths)

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
    by_row_id =
      from(c in Criterion,
        where: c.project_id == ^project_id and c.id in ^ids,
        select: {c.id, c.spec_path}
      )
      |> Repo.all()
      |> Enum.filter(fn {_id, path} -> stale?(path, present) end)
      |> Enum.map(fn {id, previous} -> {id, previous, Map.fetch!(paths, id)} end)

    # And the ones the filename cannot name.
    #
    # The id in a filename is the criterion's id *at the time the file was
    # written*, and this project renumbered its criteria. So a row whose
    # recorded path reads `criterion_8010_…` is row 2033, and matching the
    # observed file's `8010` against row ids finds nothing — the repair above
    # reaches every criterion except the ones that have been through a
    # renumbering, which are exactly the oldest and least likely to be looked at.
    #
    # Bridged through the stale record itself: it is the only thing that still
    # remembers which id the file was named for. Matched on the directory too,
    # so an id reused under a different story cannot pull a path across.
    already = MapSet.new(by_row_id, fn {id, _, _} -> id end)

    by_recorded_id =
      from(c in Criterion,
        where: c.project_id == ^project_id,
        where: not is_nil(c.spec_path) and c.spec_path != "",
        select: {c.id, c.spec_path}
      )
      |> Repo.all()
      |> Enum.reject(fn {id, _} -> MapSet.member?(already, id) end)
      |> Enum.filter(fn {_id, path} -> stale?(path, present) end)
      |> Enum.flat_map(fn {id, previous} ->
        case embedded_id(previous) do
          nil ->
            []

          embedded ->
            case Map.get(paths, embedded) do
              nil -> []
              found -> if same_dir?(previous, found), do: [{id, previous, found}], else: []
            end
        end
      end)

    count =
      (by_row_id ++ by_recorded_id)
      |> Enum.reduce(0, fn {id, previous, recorded}, acc ->
        {n, _} =
          from(c in Criterion, where: c.id == ^id and c.project_id == ^project_id)
          |> Repo.update_all(set: [spec_path: recorded, updated_at: DateTime.utc_now()])

        log_repair(id, previous, recorded)

        acc + n
      end)

    {:ok, count}
  end

  # Whether a recorded path has gone, asked of the checkout the manifest came
  # from rather than of whatever disk this process is sitting on.
  #
  # It used to be `not File.exists?(path)`, and `spec_path` is project-relative,
  # so the question resolved against the server's own cwd — the main checkout.
  # A manifest from any other working copy was therefore judged against a
  # checkout it has nothing to do with. For a worktree whose spec files are not
  # committed, every criterion read as stale, was repointed at the same relative
  # path, and read as stale again on the next manifest: a repair that could not
  # stick, because nothing it wrote could make `File.exists?` true somewhere
  # else. `bdd_specs_exist` never satisfied, and restarting or re-running the
  # task changed nothing, because the record was never what was wrong.
  # Found by devops-q-ec; issue `5b538c8b`.
  #
  # The server owns the projection and has no business consulting a filesystem
  # about a checkout it may not be in — the same mistake as `Setup.Context`
  # deciding a project's app name from whichever checkout's mix.exs sorted last
  # (`282428a3`).
  defp stale?(path, _present) when is_nil(path) or path == "", do: true

  # Evidence is additive: the record, then the disk. A path is gone only when
  # neither can find it.
  #
  # The disk clause stays deliberately. It is wrong as the *only* answer, for
  # the reason above, but it is the only thing that can speak for a path outside
  # the scanned tree — a spex somebody moved somewhere deliberate, which
  # `claim_spec_paths_test.exs` asserts must not be undone by the next scan.
  # Consulting it second can only ever find a file present, never absent, so it
  # cannot reintroduce the loop.
  defp stale?(path, present) do
    not MapSet.member?(present, path) and not File.exists?(path)
  end

  # Two sources, because neither alone is the whole picture at this moment.
  #
  # `Files.list_files/1` scopes to the caller's working copy and is the durable
  # record — but this runs *before* the manifest it is processing is upserted,
  # so a file appearing for the first time is not in it yet. The observations
  # are that missing half: a path in this manifest is a file the harness has
  # just seen on that checkout's disk.
  #
  # Union rather than either one, so a first sync does not read every existing
  # criterion as stale, and a file present but not in this manifest is not
  # mistaken for a deletion.
  defp present_paths(%Scope{} = scope, paths) do
    recorded = scope |> Files.list_files() |> MapSet.new(& &1.path)

    paths
    |> Map.values()
    |> MapSet.new()
    |> MapSet.union(recorded)
  end

  defp embedded_id(path) do
    case Regex.run(~r/criterion_(\d+)_/, Path.basename(path)) do
      [_, id] -> String.to_integer(id)
      _ -> nil
    end
  end

  defp same_dir?(a, b), do: Path.dirname(a) == Path.dirname(b)

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
  def create_criterion(%Scope{active_project: %{id: project_id}} = scope, %Story{} = story, attrs) do
    if story.project_id == project_id do
      attrs =
        attrs
        |> Map.put(:story_id, story.id)
        |> Map.put(:project_id, project_id)

      %Criterion{}
      |> Criterion.changeset(attrs)
      |> Repo.insert()
      |> restart_specs_chain(scope, story)
    else
      {:error, :cross_project}
    end
  end

  @spec update_criterion(Scope.t(), Criterion.t(), map()) ::
          {:ok, Criterion.t()} | {:error, Ecto.Changeset.t() | :cross_project}
  def update_criterion(
        %Scope{active_project: %{id: project_id}} = scope,
        %Criterion{project_id: cp_id} = criterion,
        attrs
      ) do
    if cp_id == project_id do
      criterion
      |> Criterion.changeset(attrs)
      |> Repo.update()
      |> restart_specs_chain_on_move(scope, criterion)
    else
      {:error, :cross_project}
    end
  end

  # A criterion that did not exist has never been green, so the story it lands
  # on goes back to the top.
  #
  # `specs_ready` is the latch the spex gate reads: a red spex only blocks on a
  # story where it is true, on the reasoning that such a red is a regression in
  # this working copy rather than somebody else's in-flight work. That
  # reasoning holds for a story whose criteria all went green together and
  # breaks the moment one is added afterwards — the story *was* green once, and
  # the new red is not a regression, it is work that has not happened yet.
  #
  # Which is issue 10e86fa2: a session writing seven criteria red-then-green on
  # purpose blocked every other session in the project, on a story latched by an
  # earlier pass. The stop hook re-fired the same block on every attempt and
  # there was no way to record a human's "ignore this one".
  #
  # Same shape as `clear_specs_ready_on_readiness_change/1` in `Story`, and the
  # same argument: releasing or parking a story sends it back to the top,
  # because a latch earned on the previous pass says nothing about this one.
  # Adding a criterion is that, one criterion at a time.
  #
  # The cost, chosen deliberately: while a new criterion is in flight, a genuine
  # regression in an already-green criterion on that same story also stops
  # blocking. The latch is per story and the red is per criterion; closing that
  # gap properly means recording green per criterion, which is a separate piece
  # of work.
  defp restart_specs_chain({:ok, _criterion} = ok, scope, %Story{} = story) do
    Stories.set_specs_ready(scope, story, false)
    ok
  end

  defp restart_specs_chain(other, _scope, _story), do: other

  # Moving a criterion into a story adds one to it, so the destination restarts
  # for the same reason. The story it left is not touched: losing a criterion
  # cannot make the remaining ones less green.
  defp restart_specs_chain_on_move({:ok, updated}, scope, %Criterion{story_id: was}) do
    if updated.story_id != was do
      case Repo.get(Story, updated.story_id) do
        nil -> :ok
        story -> Stories.set_specs_ready(scope, story, false)
      end
    end

    {:ok, updated}
  end

  defp restart_specs_chain_on_move(other, _scope, _criterion), do: other

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
