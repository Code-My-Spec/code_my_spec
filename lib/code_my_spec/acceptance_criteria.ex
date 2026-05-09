defmodule CodeMySpec.AcceptanceCriteria do
  @moduledoc """
  The AcceptanceCriteria context.

  Acceptance criteria belong to stories and represent testable conditions
  that define when a story is complete.

  Direct-DB implementation via `AcceptanceCriteriaRepository`. The
  `:acceptance_criteria_implementation` config key is kept as a swap point
  for test doubles.
  """

  alias CodeMySpec.AcceptanceCriteria.AcceptanceCriteriaRepository
  alias CodeMySpec.AcceptanceCriteria.Criterion
  alias CodeMySpec.Stories.Story
  alias CodeMySpec.Users.Scope

  defp impl do
    Application.get_env(
      :code_my_spec,
      :acceptance_criteria_implementation,
      AcceptanceCriteriaRepository
    )
  end

  @doc """
  Subscribes to scoped notifications about acceptance criteria changes.

    * {:created, %Criterion{}}
    * {:updated, %Criterion{}}
    * {:deleted, %Criterion{}}
  """
  def subscribe_criteria(%Scope{} = scope) do
    key = scope.active_account_id
    Phoenix.PubSub.subscribe(CodeMySpec.PubSub, "user:#{key}:acceptance_criteria")
  end

  defp broadcast(%Scope{} = scope, message) do
    key = scope.active_account_id
    Phoenix.PubSub.broadcast(CodeMySpec.PubSub, "user:#{key}:acceptance_criteria", message)
  end

  @doc "Returns the list of acceptance criteria for a story."
  def list_story_criteria(%Scope{} = scope, story_id),
    do: impl().list_story_criteria(scope, story_id)

  @doc "Gets a single acceptance criterion. Raises if not found."
  def get_criterion!(%Scope{} = scope, id), do: impl().get_criterion!(scope, id)

  @doc "Gets a single acceptance criterion. Returns nil if not found."
  def get_criterion(%Scope{} = scope, id), do: impl().get_criterion(scope, id)

  @doc "Creates an acceptance criterion for a story."
  def create_criterion(%Scope{} = scope, %Story{} = story, attrs) do
    case impl().create_criterion(scope, story, attrs) do
      {:ok, criterion} = ok ->
        broadcast(scope, {:created, criterion})
        ok

      other ->
        other
    end
  end

  @doc "Updates an acceptance criterion."
  def update_criterion(%Scope{} = scope, %Criterion{} = criterion, attrs) do
    case impl().update_criterion(scope, criterion, attrs) do
      {:ok, updated} = ok ->
        broadcast(scope, {:updated, updated})
        ok

      other ->
        other
    end
  end

  @doc "Deletes an acceptance criterion."
  def delete_criterion(%Scope{} = scope, %Criterion{} = criterion) do
    case impl().delete_criterion(scope, criterion) do
      {:ok, deleted} = ok ->
        broadcast(scope, {:deleted, deleted})
        ok

      other ->
        other
    end
  end

  @doc "Returns an `%Ecto.Changeset{}` for tracking criterion changes."
  def change_criterion(%Scope{} = scope, %Criterion{} = criterion, attrs \\ %{}) do
    true = criterion.project_id == scope.active_project.id
    Criterion.changeset(criterion, attrs)
  end

  @doc "Marks an acceptance criterion as verified."
  def mark_verified(%Scope{} = scope, %Criterion{} = criterion) do
    case impl().mark_verified(scope, criterion) do
      {:ok, updated} = ok ->
        broadcast(scope, {:updated, updated})
        ok

      other ->
        other
    end
  end

  @doc "Marks an acceptance criterion as not verified."
  def mark_unverified(%Scope{} = scope, %Criterion{} = criterion) do
    case impl().mark_unverified(scope, criterion) do
      {:ok, updated} = ok ->
        broadcast(scope, {:updated, updated})
        ok

      other ->
        other
    end
  end

  @doc """
  Imports acceptance criteria from a list of strings, creating criterion records for each.
  """
  def import_from_strings(%Scope{} = scope, %Story{} = story, strings) when is_list(strings) do
    criteria =
      Enum.map(strings, fn description ->
        {:ok, criterion} = create_criterion(scope, story, %{description: description})
        criterion
      end)

    {:ok, criteria}
  end

  @doc """
  Exports acceptance criteria for a story as a list of description strings.
  """
  def export_to_strings(%Scope{} = scope, %Story{} = story) do
    scope
    |> list_story_criteria(story.id)
    |> Enum.map(& &1.description)
  end
end
