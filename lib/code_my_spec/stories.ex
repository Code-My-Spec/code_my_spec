defmodule CodeMySpec.Stories do
  @moduledoc """
  The Stories context.

  Delegates to StoriesRepository for direct database access.
  For remote API operations (CLI/local server), use Stories.RemoteClient directly.
  """

  alias CodeMySpec.Stories.Story
  alias CodeMySpec.Users.Scope
  alias CodeMySpec.Stories.StoriesRepository

  @doc """
  Subscribes to scoped notifications about any story changes.

  The broadcasted messages match the pattern:

    * {:created, %Story{}}
    * {:updated, %Story{}}
    * {:deleted, %Story{}}

  """
  def subscribe_stories(%Scope{} = scope) do
    key = scope.active_account.id

    Phoenix.PubSub.subscribe(CodeMySpec.PubSub, "user:#{key}:stories")
  end

  defp broadcast(%Scope{active_account: nil} = _scope, _message), do: :ok

  defp broadcast(%Scope{} = scope, message) do
    Phoenix.PubSub.broadcast(
      CodeMySpec.PubSub,
      "user:#{scope.active_account_id}:stories",
      message
    )
  end

  @doc """
  Returns the list of stories.

  ## Examples

      iex> list_stories(scope)
      [%Story{}, ...]

  """
  def list_stories(scope), do: StoriesRepository.list_stories(scope)
  def list_project_stories(scope), do: StoriesRepository.list_project_stories(scope)

  @doc """
  Lists stories with pagination and optional search.
  Returns {stories, total_count}.

  Options:
  - :limit - max stories to return (default: 20)
  - :offset - stories to skip (default: 0)
  - :search - text to filter by title/description
  """
  def list_project_stories_paginated(scope, opts \\ []),
    do: StoriesRepository.list_project_stories_paginated(scope, opts)

  @doc """
  Lists just story IDs and titles (lightweight, no criteria).
  Returns list of %{id, title, component_id}.

  Options:
  - :search - text to filter by title
  """
  def list_story_titles(scope, opts \\ []),
    do: StoriesRepository.list_story_titles(scope, opts)

  def list_project_stories_by_priority(scope),
    do: StoriesRepository.list_project_stories_by_priority(scope)

  def list_unsatisfied_stories(scope), do: StoriesRepository.list_unsatisfied_stories(scope)

  def list_component_stories(scope, component_id),
    do: StoriesRepository.list_component_stories(scope, component_id)

  @doc """
  Gets a single story.

  Raises `Ecto.NoResultsError` if the Story does not exist.

  ## Examples

      iex> get_story!(123)
      %Story{}

      iex> get_story!(456)
      ** (Ecto.NoResultsError)

  """
  def get_story!(scope, id), do: StoriesRepository.get_story!(scope, id)
  def get_story(scope, id), do: StoriesRepository.get_story(scope, id)

  @doc """
  Creates a story.

  ## Examples

      iex> create_story(%{field: value})
      {:ok, %Story{}}

      iex> create_story(%{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  def create_story(%Scope{} = scope, attrs) do
    with {:ok, story = %Story{}} <- StoriesRepository.create_story(scope, attrs) do
      broadcast(scope, {:created, story})
      {:ok, story}
    end
  end

  @doc """
  Updates a story.

  ## Examples

      iex> update_story(story, %{field: new_value})
      {:ok, %Story{}}

      iex> update_story(story, %{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  def update_story(%Scope{} = scope, %Story{} = story, attrs) do
    true = story.account_id == scope.active_account.id

    with {:ok, story = %Story{}} <- StoriesRepository.update_story(scope, story, attrs) do
      broadcast(scope, {:updated, story})
      {:ok, story}
    end
  end

  @doc """
  Deletes a story.

  ## Examples

      iex> delete_story(story)
      {:ok, %Story{}}

      iex> delete_story(story)
      {:error, %Ecto.Changeset{}}

  """
  def delete_story(%Scope{} = scope, %Story{} = story) do
    true = story.account_id == scope.active_account.id

    with {:ok, story = %Story{}} <- StoriesRepository.delete_story(scope, story) do
      broadcast(scope, {:deleted, story})
      {:ok, story}
    end
  end

  @doc """
  Returns an `%Ecto.Changeset{}` for tracking story changes.

  ## Examples

      iex> change_story(story)
      %Ecto.Changeset{data: %Story{}}

  """
  def change_story(%Scope{} = scope, %Story{} = story, attrs \\ %{}) do
    true = story.account_id == scope.active_account.id

    Story.changeset(story, attrs)
  end

  @doc """
  Sets the component that satisfies a story.

  ## Examples

      iex> set_story_component(scope, story, component_id)
      {:ok, %Story{}}

      iex> set_story_component(scope, story, invalid_component_id)
      {:error, %Ecto.Changeset{}}

  """
  def set_story_component(%Scope{} = scope, %Story{} = story, component_id) do
    # Support both full account struct and account_id only (CLI context)
    # Skip authorization check if no account context (MCP/CLI mode with project-only scope)
    account_id =
      if scope.active_account, do: scope.active_account.id, else: scope.active_account_id

    if account_id && story.account_id != account_id do
      {:error, :unauthorized}
    else
      with {:ok, story = %Story{}} <-
             StoriesRepository.set_story_component(scope, story, component_id) do
        broadcast(scope, {:updated, story})
        {:ok, story}
      end
    end
  end

  @doc """
  Clears the component assignment from a story.

  ## Examples

      iex> clear_story_component(scope, story)
      {:ok, %Story{}}

  """
  def clear_story_component(%Scope{} = scope, %Story{} = story) do
    account_id =
      if scope.active_account, do: scope.active_account.id, else: scope.active_account_id

    if account_id && story.account_id != account_id do
      {:error, :unauthorized}
    else
      with {:ok, story = %Story{}} <- StoriesRepository.clear_story_component(scope, story) do
        broadcast(scope, {:updated, story})
        {:ok, story}
      end
    end
  end
end
