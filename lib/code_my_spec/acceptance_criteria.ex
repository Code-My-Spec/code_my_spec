defmodule CodeMySpec.AcceptanceCriteria do
  @moduledoc """
  The AcceptanceCriteria context.

  Phoenix context for managing acceptance criteria as first-class entities.
  Acceptance criteria belong to stories and represent testable conditions
  that define when a story is complete.
  """

  alias CodeMySpec.AcceptanceCriteria.AcceptanceCriteriaRepository
  alias CodeMySpec.AcceptanceCriteria.Criterion
  alias CodeMySpec.Stories.Story
  alias CodeMySpec.Users.Scope

  @doc """
  Subscribes to scoped notifications about acceptance criteria changes.

  The broadcasted messages match the pattern:

    * {:created, %Criterion{}}
    * {:updated, %Criterion{}}
    * {:deleted, %Criterion{}}

  """
  def subscribe_criteria(%Scope{} = scope) do
    key = scope.active_account.id
    Phoenix.PubSub.subscribe(CodeMySpec.PubSub, "user:#{key}:acceptance_criteria")
  end

  defp broadcast(%Scope{} = scope, message) do
    key = scope.active_account.id
    Phoenix.PubSub.broadcast(CodeMySpec.PubSub, "user:#{key}:acceptance_criteria", message)
  end

  @doc """
  Returns the list of acceptance criteria for a story.
  """
  defdelegate list_story_criteria(scope, story_id), to: AcceptanceCriteriaRepository

  @doc """
  Gets a single acceptance criterion.

  Raises `Ecto.NoResultsError` if the Criterion does not exist.
  """
  defdelegate get_criterion!(scope, id), to: AcceptanceCriteriaRepository

  @doc """
  Gets a single acceptance criterion.

  Returns nil if the Criterion does not exist.
  """
  defdelegate get_criterion(scope, id), to: AcceptanceCriteriaRepository

  @doc """
  Creates an acceptance criterion for a story.
  """
  def create_criterion(%Scope{} = scope, %Story{} = story, attrs) do
    true = story.project_id == scope.active_project.id

    attrs =
      attrs
      |> Map.put(:story_id, story.id)
      |> Map.put(:project_id, scope.active_project.id)

    with {:ok, criterion = %Criterion{}} <- AcceptanceCriteriaRepository.create_criterion(attrs) do
      broadcast(scope, {:created, criterion})
      {:ok, criterion}
    end
  end

  @doc """
  Updates an acceptance criterion.
  """
  def update_criterion(%Scope{} = scope, %Criterion{} = criterion, attrs) do
    true = criterion.project_id == scope.active_project.id

    with {:ok, criterion = %Criterion{}} <-
           AcceptanceCriteriaRepository.update_criterion(criterion, attrs) do
      broadcast(scope, {:updated, criterion})
      {:ok, criterion}
    end
  end

  @doc """
  Deletes an acceptance criterion.
  """
  def delete_criterion(%Scope{} = scope, %Criterion{} = criterion) do
    true = criterion.project_id == scope.active_project.id

    with {:ok, criterion = %Criterion{}} <-
           AcceptanceCriteriaRepository.delete_criterion(criterion) do
      broadcast(scope, {:deleted, criterion})
      {:ok, criterion}
    end
  end

  @doc """
  Returns an `%Ecto.Changeset{}` for tracking criterion changes.
  """
  def change_criterion(%Scope{} = scope, %Criterion{} = criterion, attrs \\ %{}) do
    true = criterion.project_id == scope.active_project.id

    Criterion.changeset(criterion, attrs)
  end

  @doc """
  Marks an acceptance criterion as verified.
  """
  def mark_verified(%Scope{} = scope, %Criterion{} = criterion) do
    true = criterion.project_id == scope.active_project.id

    attrs = %{
      verified: true,
      verified_at: DateTime.utc_now()
    }

    with {:ok, criterion = %Criterion{}} <-
           AcceptanceCriteriaRepository.update_criterion(criterion, attrs) do
      broadcast(scope, {:updated, criterion})
      {:ok, criterion}
    end
  end

  @doc """
  Marks an acceptance criterion as not verified.
  """
  def mark_unverified(%Scope{} = scope, %Criterion{} = criterion) do
    true = criterion.project_id == scope.active_project.id

    attrs = %{
      verified: false,
      verified_at: nil
    }

    with {:ok, criterion = %Criterion{}} <-
           AcceptanceCriteriaRepository.update_criterion(criterion, attrs) do
      broadcast(scope, {:updated, criterion})
      {:ok, criterion}
    end
  end

  @doc """
  Imports acceptance criteria from a list of strings, creating criterion records for each.
  """
  def import_from_strings(%Scope{} = scope, %Story{} = story, strings) when is_list(strings) do
    true = story.project_id == scope.active_project.id

    criteria =
      Enum.map(strings, fn description ->
        attrs = %{
          description: description,
          story_id: story.id,
          project_id: scope.active_project.id
        }

        {:ok, criterion} = AcceptanceCriteriaRepository.create_criterion(attrs)
        broadcast(scope, {:created, criterion})
        criterion
      end)

    {:ok, criteria}
  end

  @doc """
  Exports acceptance criteria for a story as a list of description strings.
  """
  def export_to_strings(%Scope{} = scope, %Story{} = story) do
    scope
    |> AcceptanceCriteriaRepository.list_story_criteria(story.id)
    |> Enum.map(& &1.description)
  end
end
