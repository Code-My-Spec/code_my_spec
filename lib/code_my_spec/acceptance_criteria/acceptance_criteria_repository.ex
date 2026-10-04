defmodule CodeMySpec.AcceptanceCriteria.AcceptanceCriteriaRepository do
  @moduledoc """
  Direct-DB implementation of the AcceptanceCriteria interface.
  """

  import Ecto.Query, warn: false

  alias CodeMySpec.AcceptanceCriteria.Criterion
  alias CodeMySpec.Repo
  alias CodeMySpec.Stories
  alias CodeMySpec.Stories.Story
  alias CodeMySpec.Users.Scope

  @doc """
  Every claimed spec path in the project, mapped to the story that owns it.

  Recorded paths predate criteria numbers in spex files; this reads them back. Anything deciding what a spex failure
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
  # `id` breaks the tie, and the tie is the common case rather than the rare one.
  #
  # `inserted_at` is second-resolution, and criteria are written together — a
  # three-amigos session adds four in one call, a fixture adds three in a row.
  # They share a timestamp, Postgres is free to return equal keys in any order,
  # and "creation order" came back shuffled. Reproduced with
  # `--repeat-until-failure 10` on `export_to_strings/2`, which is the one place
  # that ordering is load-bearing: it is what renders a story's criteria to an
  # agent, so a shuffle reorders the work.
  def list_story_criteria(%Scope{active_project: %{id: project_id}}, story_id) do
    from(c in Criterion,
      where: c.story_id == ^story_id and c.project_id == ^project_id and is_nil(c.retired_at),
      order_by: [asc: c.inserted_at, asc: c.id]
    )
    |> Repo.all()
  end

  @doc "A story's criteria, retired ones included. Migration carries both."
  @spec list_all_story_criteria(Scope.t(), integer()) :: [Criterion.t()]
  def list_all_story_criteria(%Scope{active_project: %{id: project_id}}, story_id) do
    from(c in Criterion,
      where: c.story_id == ^story_id and c.project_id == ^project_id,
      order_by: [asc: c.inserted_at, asc: c.id]
    )
    |> Repo.all()
  end

  @doc "A criterion by its number, retired or not."
  @spec get_criterion_by_number(Scope.t(), integer() | String.t()) :: Criterion.t() | nil
  def get_criterion_by_number(%Scope{active_project: %{id: project_id}}, number)
      when is_integer(number),
      do: Repo.get_by(Criterion, number: number, project_id: project_id)

  def get_criterion_by_number(%Scope{} = scope, number) when is_binary(number) do
    case Integer.parse(number) do
      {n, ""} -> get_criterion_by_number(scope, n)
      _ -> nil
    end
  end

  @doc "The project's criteria with these numbers, retired ones included."
  @spec list_criteria_by_number(Scope.t(), [integer()]) :: [Criterion.t()]
  def list_criteria_by_number(_scope, []), do: []

  def list_criteria_by_number(%Scope{active_project_id: project_id}, numbers) do
    from(c in Criterion, where: c.project_id == ^project_id and c.number in ^numbers)
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

  @spec retire_criterion(Scope.t(), Criterion.t()) ::
          {:ok, Criterion.t()} | {:error, Ecto.Changeset.t() | :cross_project}
  def retire_criterion(%Scope{active_project: %{id: project_id}}, %Criterion{project_id: project_id} = criterion),
    do: criterion |> Criterion.retire_changeset() |> Repo.update()

  def retire_criterion(_scope, _criterion), do: {:error, :cross_project}

  @spec latch_criterion(Scope.t(), Criterion.t()) ::
          {:ok, Criterion.t()} | {:error, Ecto.Changeset.t() | :cross_project}
  def latch_criterion(%Scope{active_project: %{id: project_id}}, %Criterion{project_id: project_id} = criterion),
    do: criterion |> Criterion.latch_changeset() |> Repo.update()

  def latch_criterion(_scope, _criterion), do: {:error, :cross_project}

  # Coming back is a criterion arriving on its story, so the story restarts
  # the same way it does for a new one.
  @spec restore_criterion(Scope.t(), Criterion.t()) ::
          {:ok, Criterion.t()} | {:error, Ecto.Changeset.t() | :cross_project}
  def restore_criterion(%Scope{active_project: %{id: project_id}} = scope, %Criterion{project_id: project_id} = criterion) do
    criterion
    |> Criterion.restore_changeset()
    |> Repo.update()
    |> restart_specs_chain(scope, Repo.get!(Story, criterion.story_id))
  end

  def restore_criterion(_scope, _criterion), do: {:error, :cross_project}

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
