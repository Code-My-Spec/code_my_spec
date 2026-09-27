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

  use Boundary,
    top_level?: true,
    deps: [
      CodeMySpec.Repo,
      CodeMySpec.Stories,
      CodeMySpec.Users.Scope,
      CodeMySpec.Utils
    ],
    exports: :all

  import Ecto.Query, only: [from: 2, where: 3]

  alias CodeMySpec.Epics.Epic
  alias CodeMySpec.Epics.EpicsRepository
  alias CodeMySpec.Repo
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

  @type dispatch_state ::
          {:work_to_assign, [Epic.t()]}
          | {:nothing_to_assign, :in_progress}
          | {:nothing_to_assign, :all_assigned}

  @doc """
  Whether the main agent has work to assign, and why not when it has none.

  A reason rather than a boolean because the two ways of having nothing to do
  mean opposite things. Nothing in progress and nothing left is a finished
  project; nothing in progress with work waiting is the one state that wants
  somebody to act, and a node that reported them the same way would either nag a
  finished project forever or go quiet on one that is stuck.
  """
  @spec dispatch_state(Scope.t()) :: dispatch_state()
  def dispatch_state(%Scope{active_project_id: project_id} = scope)
      when is_binary(project_id) do
    cond do
      in_progress?(project_id) -> {:nothing_to_assign, :in_progress}
      unassigned(scope) == [] -> {:nothing_to_assign, :all_assigned}
      true -> {:work_to_assign, unassigned(scope)}
    end
  end

  def dispatch_state(%Scope{}), do: {:nothing_to_assign, :all_assigned}

  # Anything dispatched and not finished. A failed epic is not in progress —
  # that is the distinction `record_failure/3` exists to make, and counting it
  # as busy would leave a project that fell over reporting itself as working.
  @doc """
  Whether anything dispatched is still being built.

  Here rather than in `EpicDispatch` because the requirement graph asks it,
  and the graph sits below dispatch: it reads epics, it does not call the code
  that acts on them. (It went through `EpicDispatch` from 2026-09-16 only
  because `Epics` was not yet a declared dependency of `Requirements`.)
  """
  @spec in_progress?(Scope.t()) :: boolean()
  def in_progress?(%Scope{active_project_id: project_id}) when is_binary(project_id),
    do: in_progress?(project_id)

  def in_progress?(%Scope{}), do: false

  def in_progress?(project_id) when is_binary(project_id) do
    Repo.exists?(from e in Epic, where: e.project_id == ^project_id and e.status == :dispatched)
  end

  # Stories that are ready and belong to no epic. Ready matters: an unshaped
  # story is not work waiting to be assigned, it is work waiting to be shaped,
  # and proposing it would put the wrong thing in front of somebody.
  defp unassigned(%Scope{active_project_id: project_id}) do
    Story
    |> where([s], s.project_id == ^project_id and s.ready_for_dev == true and is_nil(s.epic_id))
    |> Repo.all()
  end
end
