defmodule CodeMySpec.Epics.EpicsRepository do
  @moduledoc """
  Ecto queries for epics. All queries are scoped to the active project;
  cross-project operations are rejected.

  Epics are organizational only. Releasing an epic's stories is a one-shot
  bulk edit of the stories that are in it at that moment — there is no stored
  epic-level readiness that could cascade later.
  """

  import Ecto.Query, warn: false

  alias CodeMySpec.Epics.Epic
  alias CodeMySpec.Repo
  alias CodeMySpec.Stories.Story
  alias CodeMySpec.Users.Scope

  @type attrs :: map()

  @spec list_epics(Scope.t()) :: [Epic.t()]
  def list_epics(%Scope{active_project_id: project_id}) when not is_nil(project_id) do
    Epic
    |> where([e], e.project_id == ^project_id)
    |> order_by([e], asc: e.name)
    |> preload(:stories)
    |> Repo.all()
  end

  def list_epics(%Scope{}), do: []

  @spec get_epic(Scope.t(), Ecto.UUID.t()) :: Epic.t() | nil
  def get_epic(%Scope{active_project_id: project_id}, id) when not is_nil(project_id) do
    Epic
    |> where([e], e.project_id == ^project_id and e.id == ^id)
    |> preload(:stories)
    |> Repo.one()
  end

  def get_epic(%Scope{}, _id), do: nil

  @spec get_epic_by_slug(Scope.t(), String.t()) :: Epic.t() | nil
  def get_epic_by_slug(%Scope{active_project_id: project_id}, slug)
      when not is_nil(project_id) do
    Epic
    |> where([e], e.project_id == ^project_id and e.slug == ^slug)
    |> preload(:stories)
    |> Repo.one()
  end

  def get_epic_by_slug(%Scope{}, _slug), do: nil

  @spec get_epic_by_name(Scope.t(), String.t()) :: Epic.t() | nil
  def get_epic_by_name(%Scope{active_project_id: project_id}, name)
      when not is_nil(project_id) do
    Epic
    |> where([e], e.project_id == ^project_id and e.name == ^name)
    |> preload(:stories)
    |> Repo.one()
  end

  def get_epic_by_name(%Scope{}, _name), do: nil

  @spec create_epic(Scope.t(), attrs()) ::
          {:ok, Epic.t()} | {:error, :missing_active_project | Ecto.Changeset.t()}
  def create_epic(%Scope{active_project_id: project_id} = scope, attrs)
      when not is_nil(project_id) do
    attrs =
      attrs
      |> normalize()
      |> Map.put(:project_id, project_id)
      |> Map.put(:account_id, scope.active_account_id)

    %Epic{}
    |> Epic.changeset(attrs)
    |> Repo.insert()
  end

  def create_epic(%Scope{}, _attrs), do: {:error, :missing_active_project}

  @spec update_epic(Scope.t(), Epic.t(), attrs()) ::
          {:ok, Epic.t()}
          | {:error, :missing_active_project | :cross_project | Ecto.Changeset.t()}
  def update_epic(%Scope{active_project_id: project_id}, %Epic{} = epic, attrs)
      when not is_nil(project_id) do
    if epic.project_id == project_id do
      epic
      |> Epic.changeset(attrs |> normalize() |> Map.delete(:project_id))
      |> Repo.update()
    else
      {:error, :cross_project}
    end
  end

  def update_epic(%Scope{}, _epic, _attrs), do: {:error, :missing_active_project}

  @spec delete_epic(Scope.t(), Epic.t()) ::
          {:ok, Epic.t()} | {:error, :missing_active_project | :cross_project}
  def delete_epic(%Scope{active_project_id: project_id}, %Epic{} = epic)
      when not is_nil(project_id) do
    if epic.project_id == project_id do
      Repo.delete(epic)
    else
      {:error, :cross_project}
    end
  end

  def delete_epic(%Scope{}, _epic), do: {:error, :missing_active_project}

  @doc """
  Moves a story into an epic. A story belongs to at most one epic, so this
  replaces any previous membership rather than adding to it.

  Pass `nil` as the epic to remove the story from its epic.
  """
  @spec assign_story(Scope.t(), Story.t(), Epic.t() | nil) ::
          {:ok, Story.t()} | {:error, :missing_active_project | :cross_project}
  def assign_story(%Scope{active_project_id: project_id}, %Story{} = story, epic)
      when not is_nil(project_id) do
    epic_id = if epic, do: epic.id, else: nil

    cond do
      story.project_id != project_id ->
        {:error, :cross_project}

      epic && epic.project_id != project_id ->
        {:error, :cross_project}

      true ->
        story
        |> Ecto.Changeset.change(%{epic_id: epic_id})
        |> Repo.update()
    end
  end

  def assign_story(%Scope{}, _story, _epic), do: {:error, :missing_active_project}

  @doc """
  One-shot bulk edit: stamps `ready_for_dev` onto every story that is in the
  epic right now. Stories added later are unaffected — the epic carries no
  readiness of its own.

  Returns the number of stories stamped.
  """
  @spec set_epic_stories_ready(Scope.t(), Epic.t(), boolean()) ::
          {:ok, non_neg_integer()} | {:error, :missing_active_project | :cross_project}
  def set_epic_stories_ready(%Scope{active_project_id: project_id}, %Epic{} = epic, ready?)
      when not is_nil(project_id) and is_boolean(ready?) do
    if epic.project_id == project_id do
      {count, _} =
        Story
        |> where([s], s.project_id == ^project_id and s.epic_id == ^epic.id)
        |> Repo.update_all(set: [ready_for_dev: ready?])

      {:ok, count}
    else
      {:error, :cross_project}
    end
  end

  def set_epic_stories_ready(%Scope{}, _epic, _ready?), do: {:error, :missing_active_project}

  defp normalize(attrs) when is_map(attrs) do
    Map.new(attrs, fn
      {k, v} when is_binary(k) -> {String.to_existing_atom(k), v}
      {k, v} -> {k, v}
    end)
  rescue
    ArgumentError -> attrs
  end
end
