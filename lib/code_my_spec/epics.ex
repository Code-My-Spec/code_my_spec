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
      CodeMySpec.Agents.Agent,
      CodeMySpec.Configurations,
      CodeMySpec.Issues,
      CodeMySpec.Repo,
      CodeMySpec.Stories,
      CodeMySpec.Users.Scope,
      CodeMySpec.Utils
    ],
    exports: :all

  import Ecto.Query, only: [from: 2, where: 3]

  alias CodeMySpec.Agents.Agent
  alias CodeMySpec.Configurations
  alias CodeMySpec.Epics.Epic
  alias CodeMySpec.Epics.EpicsRepository
  alias CodeMySpec.Issues
  alias CodeMySpec.Issues.Issue
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

  @type waiting :: %{fixes: [Story.t()], ready: [Story.t()]}

  @type dispatch_state ::
          {:work_to_assign, waiting()}
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
    if in_progress?(project_id) do
      {:nothing_to_assign, :in_progress}
    else
      fixes = offered_fixes(scope)
      awaiting_dispatch(candidates(scope, fixes), fixes)
    end
  end

  def dispatch_state(%Scope{}), do: {:nothing_to_assign, :all_assigned}

  @doc """
  What waits for a team, from rows the caller already holds.

  Two kinds, kept apart because main acts on them differently. `fixes`: stories
  holding a fix no team has (`Issue.fix_offered?/2`), worst severity first. The
  issue was accepted, so the work is approved; epic, `ready_for_dev` and the
  promotion stamp do not matter, and most legacy-promoted stories sit in draft
  epics. A story already on a copy is that team's. `ready`: shaped stories in no
  epic and not yet promoted, to be grouped and sent for approval.
  """
  @spec awaiting_dispatch([Story.t()], [Issue.t()]) :: dispatch_state()
  def awaiting_dispatch(stories, fixes) do
    worst = worst_severity_by_story(fixes)

    waiting = %{
      fixes:
        stories
        |> Enum.filter(&(Map.has_key?(worst, &1.id) and unheld?(&1)))
        |> Enum.sort_by(
          &{Map.fetch!(worst, &1.id), DateTime.to_unix(&1.inserted_at, :microsecond)}
        ),
      ready: Enum.filter(stories, &(ready_unassigned?(&1) and not Map.has_key?(worst, &1.id)))
    }

    case waiting do
      %{fixes: [], ready: []} -> {:nothing_to_assign, :all_assigned}
      waiting -> {:work_to_assign, waiting}
    end
  end

  # Anything dispatched and not finished, or any agent holding a claimed task.
  # A failed epic is not in progress — that is the distinction
  # `record_failure/3` exists to make, and counting it as busy would leave a
  # project that fell over reporting itself as working.
  @doc """
  Whether anything dispatched is still being built.

  Here rather than in `EpicDispatch` because the requirement graph asks it,
  and the graph sits below dispatch: it reads epics, it does not call the code
  that acts on them. (It went through `EpicDispatch` from 2026-09-16 only
  because `Epics` was not yet a declared dependency of `Requirements`.)

  Checked alongside a dispatched epic rather than instead of one: an agent can
  hold a claimed task on a story that was never grouped into an epic (QA's own
  follow-up work, an issue fix), and that is still work in progress, not an
  invitation to propose another epic on top of it. Reads `Agent` directly — a
  declared schema leaf for exactly this (John, 2026-10-04) — rather than
  `Agents` itself, which depends on `Requirements` and would cycle back here.
  """
  @spec in_progress?(Scope.t()) :: boolean()
  def in_progress?(%Scope{active_project_id: project_id}) when is_binary(project_id),
    do: in_progress?(project_id)

  def in_progress?(%Scope{}), do: false

  def in_progress?(project_id) when is_binary(project_id) do
    Repo.exists?(from e in Epic, where: e.project_id == ^project_id and e.status == :dispatched) or
      any_claimed_task?(project_id)
  end

  defp any_claimed_task?(project_id) do
    Agent
    |> where([a], a.project_id == ^project_id)
    |> Repo.all()
    |> Enum.any?(fn agent -> Enum.any?(agent.tasks || [], &(&1.status == :active)) end)
  end

  # `ready_for_dev` is product's approval and stays set after delivery
  # (clearing it on promotion would un-project the story's own requirement
  # graph — issue b6462c09), so a shipped story is excluded from `ready` by its
  # stamp rather than by changing what "ready" means.
  defp ready_unassigned?(story),
    do: story.ready_for_dev == true and is_nil(story.epic_id) and is_nil(story.promoted_version)

  defp unheld?(story), do: is_nil(story.working_copy_id) and is_nil(story.retired_at)

  defp worst_severity_by_story(fixes) do
    fixes
    |> Enum.reject(&is_nil(&1.story_id))
    |> Enum.group_by(& &1.story_id, &Issue.severity_index(&1.severity))
    |> Map.new(fn {story_id, indexes} -> {story_id, Enum.min(indexes)} end)
  end

  defp offered_fixes(scope) do
    threshold = Configurations.fix_issues_min_severity(scope)

    scope
    |> Issues.list_by_status_and_min_severity(:accepted, threshold)
    |> Enum.filter(&(not is_nil(&1.story_id) and Issue.fix_offered?(&1, threshold)))
  end

  defp candidates(%Scope{active_project_id: project_id}, fixes) do
    fix_story_ids = Enum.map(fixes, & &1.story_id)

    Story
    |> where(
      [s],
      s.project_id == ^project_id and
        ((s.ready_for_dev == true and is_nil(s.epic_id) and is_nil(s.promoted_version)) or
           s.id in ^fix_story_ids)
    )
    |> Repo.all()
  end
end
