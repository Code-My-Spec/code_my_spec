defmodule CodeMySpec.Stories.AcceptanceCriteria do
  @moduledoc """
  The AcceptanceCriteria context.

  Acceptance criteria belong to stories and represent testable conditions
  that define when a story is complete.

  Direct-DB implementation via `AcceptanceCriteriaRepository`. The
  `:acceptance_criteria_implementation` config key is kept as a swap point
  for test doubles.
  """

  alias CodeMySpec.Requirements.GraphInputs
  alias CodeMySpec.Stories.AcceptanceCriteria.AcceptanceCriteriaRepository
  alias CodeMySpec.Stories.AcceptanceCriteria.Criterion
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
  """
  def subscribe_criteria(%Scope{} = scope) do
    key = scope.active_account_id
    Phoenix.PubSub.subscribe(CodeMySpec.PubSub, "user:#{key}:acceptance_criteria")
  end

  defp broadcast(%Scope{} = scope, message) do
    key = scope.active_account_id
    Phoenix.PubSub.broadcast(CodeMySpec.PubSub, "user:#{key}:acceptance_criteria", message)

    GraphInputs.announce(
      scope,
      "AcceptanceCriteria",
      GraphInputs.story_entities(message),
      :project_wide
    )
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

  @doc "Retires a criterion. There is no delete: a retired one keeps its number."
  def retire_criterion(%Scope{} = scope, %Criterion{} = criterion) do
    case impl().retire_criterion(scope, criterion) do
      {:ok, retired} = ok ->
        broadcast(scope, {:updated, retired})
        ok

      other ->
        other
    end
  end

  @doc "Brings a retired criterion back under its number."
  def restore_criterion(%Scope{} = scope, %Criterion{} = criterion) do
    case impl().restore_criterion(scope, criterion) do
      {:ok, restored} = ok ->
        broadcast(scope, {:updated, restored})
        ok

      other ->
        other
    end
  end

  @doc """
  Latches a criterion directly, as a certifying run would (story 983,
  criteria 1895-1906). The criterion's own counterpart to
  `Stories.set_specs_ready/4` — what certifies it and what reads the latch
  back belong to the callers that do so.
  """
  def latch_criterion(%Scope{} = scope, %Criterion{} = criterion) do
    case impl().latch_criterion(scope, criterion) do
      {:ok, latched} = ok ->
        broadcast(scope, {:updated, latched})
        ok

      other ->
        other
    end
  end

  @doc """
  Unlatches a criterion directly, as a rewritten spex would (story 983,
  criterion 1897). The counterpart to `latch_criterion/2`.
  """
  def unlatch_criterion(%Scope{} = scope, %Criterion{} = criterion) do
    case impl().unlatch_criterion(scope, criterion) do
      {:ok, unlatched} = ok ->
        broadcast(scope, {:updated, unlatched})
        ok

      other ->
        other
    end
  end

  @doc "Every latched, live criterion, project-wide, with its story preloaded."
  @spec list_latched_criteria(Scope.t()) :: [Criterion.t()]
  def list_latched_criteria(%Scope{} = scope), do: impl().list_latched_criteria(scope)

  @doc "A story's criteria, retired ones included."
  def list_all_story_criteria(%Scope{} = scope, story_id),
    do: impl().list_all_story_criteria(scope, story_id)

  @doc "The project's criteria with these numbers, retired ones included."
  def list_criteria_by_number(%Scope{} = scope, numbers),
    do: impl().list_criteria_by_number(scope, numbers)

  @doc "A criterion by its number, retired or not. Returns nil if not found."
  def get_criterion_by_number(%Scope{} = scope, number),
    do: impl().get_criterion_by_number(scope, number)

  @doc "Returns an `%Ecto.Changeset{}` for tracking criterion changes."
  def change_criterion(%Scope{} = scope, %Criterion{} = criterion, attrs \\ %{}) do
    true = criterion.project_id == scope.active_project.id
    Criterion.changeset(criterion, attrs)
  end

  @doc "Every claimed spec path in the project, mapped to the story that owns it."
  @spec spec_path_story_ids(Scope.t()) :: %{String.t() => integer()}
  def spec_path_story_ids(%Scope{} = scope), do: impl().spec_path_story_ids(scope)

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
