defmodule CodeMySpec.AcceptanceCriteria.AcceptanceCriteriaRepository do
  @moduledoc """
  Direct-DB implementation of the AcceptanceCriteria interface.

  Used on the server (canonical store, Postgres). The CLI swaps in
  `AcceptanceCriteria.RemoteClient` via the `:acceptance_criteria_implementation`
  config key.
  """

  import Ecto.Query, warn: false

  alias CodeMySpec.AcceptanceCriteria.Criterion
  alias CodeMySpec.Repo
  alias CodeMySpec.Stories.Story
  alias CodeMySpec.Users.Scope

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
  def delete_criterion(%Scope{active_project: %{id: project_id}}, %Criterion{
        project_id: cp_id
      } = criterion) do
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
