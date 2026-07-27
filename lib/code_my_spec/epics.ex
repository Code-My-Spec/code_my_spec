defmodule CodeMySpec.Epics do
  @moduledoc """
  The Epics context.

  An epic is a named, user-managed collection of user stories. A story
  belongs to at most one epic.

  Epics are **organizational only** — they carry no execution semantics.
  What gates development is `ready_for_dev` on the story itself; releasing
  an epic is a one-shot bulk edit of the stories in it at that moment, not a
  live cascade.
  """

  alias CodeMySpec.Epics.Epic
  alias CodeMySpec.Epics.EpicsRepository
  alias CodeMySpec.Stories.Story
  alias CodeMySpec.Users.Scope

  @doc """
  Subscribes to scoped notifications about epic changes.

  Broadcasts match the pattern:

    * {:epic_created, %Epic{}}
    * {:epic_updated, %Epic{}}
    * {:epic_deleted, %Epic{}}
    * {:epic_stories_released, %{epic_id: _, count: _, ready_for_dev: _}}

  """
  def subscribe(%Scope{} = scope) do
    Phoenix.PubSub.subscribe(CodeMySpec.PubSub, topic(scope))
  end

  defdelegate list_epics(scope), to: EpicsRepository
  defdelegate get_epic(scope, id), to: EpicsRepository
  defdelegate get_epic_by_slug(scope, slug), to: EpicsRepository
  defdelegate get_epic_by_name(scope, name), to: EpicsRepository

  @spec create_epic(Scope.t(), map()) ::
          {:ok, Epic.t()} | {:error, :missing_active_project | Ecto.Changeset.t()}
  def create_epic(%Scope{} = scope, attrs) do
    with {:ok, epic} <- EpicsRepository.create_epic(scope, attrs) do
      broadcast(scope, {:epic_created, epic})
      {:ok, epic}
    end
  end

  @spec update_epic(Scope.t(), Epic.t(), map()) ::
          {:ok, Epic.t()}
          | {:error, :missing_active_project | :cross_project | Ecto.Changeset.t()}
  def update_epic(%Scope{} = scope, %Epic{} = epic, attrs) do
    with {:ok, updated} <- EpicsRepository.update_epic(scope, epic, attrs) do
      broadcast(scope, {:epic_updated, updated})
      {:ok, updated}
    end
  end

  @spec delete_epic(Scope.t(), Epic.t()) ::
          {:ok, Epic.t()} | {:error, :missing_active_project | :cross_project}
  def delete_epic(%Scope{} = scope, %Epic{} = epic) do
    with {:ok, deleted} <- EpicsRepository.delete_epic(scope, epic) do
      broadcast(scope, {:epic_deleted, deleted})
      {:ok, deleted}
    end
  end

  @spec assign_story(Scope.t(), Story.t(), Epic.t() | nil) ::
          {:ok, Story.t()} | {:error, :missing_active_project | :cross_project}
  defdelegate assign_story(scope, story, epic), to: EpicsRepository

  @doc """
  Stamps `ready_for_dev` onto every story currently in the epic and returns
  how many were stamped. Stories added to the epic afterwards are unaffected.
  """
  @spec set_epic_stories_ready(Scope.t(), Epic.t(), boolean()) ::
          {:ok, non_neg_integer()} | {:error, :missing_active_project | :cross_project}
  def set_epic_stories_ready(%Scope{} = scope, %Epic{} = epic, ready?) do
    with {:ok, count} <- EpicsRepository.set_epic_stories_ready(scope, epic, ready?) do
      broadcast(
        scope,
        {:epic_stories_released, %{epic_id: epic.id, count: count, ready_for_dev: ready?}}
      )

      {:ok, count}
    end
  end

  @spec change_epic(Epic.t(), map()) :: Ecto.Changeset.t()
  def change_epic(%Epic{} = epic, attrs \\ %{}), do: Epic.changeset(epic, attrs)

  defp topic(%Scope{active_project_id: project_id}), do: "project:#{project_id}:epics"

  defp broadcast(%Scope{} = scope, message) do
    Phoenix.PubSub.broadcast(CodeMySpec.PubSub, topic(scope), message)
  end
end
