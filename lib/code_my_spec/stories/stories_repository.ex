defmodule CodeMySpec.Stories.StoriesRepository do
  @moduledoc false

  import Ecto.Query, warn: false

  alias CodeMySpec.Accounts.Account
  alias CodeMySpec.Projects.Project
  alias CodeMySpec.Repo
  alias CodeMySpec.Stories.Story
  alias CodeMySpec.Users.Scope

  def list_stories(%Scope{} = scope) do
    Story
    |> Repo.all_by(project_id: scope.active_project.id)
    |> Repo.preload([:criteria, :tags])
  end

  def list_project_stories(%Scope{} = scope) do
    stories =
      Story
      |> Repo.all_by(project_id: scope.active_project.id)
      |> Repo.preload([:criteria, :tags])

    {:ok, stories}
  end

  def project_has_stories?(%Scope{} = scope) do
    Repo.exists?(from s in Story, where: s.project_id == ^scope.active_project.id)
  end

  @doc """
  Lists stories with pagination and optional search.
  Returns {stories, total_count}.
  """
  def list_project_stories_paginated(%Scope{} = scope, opts \\ []) do
    limit = Keyword.get(opts, :limit, 20)
    offset = Keyword.get(opts, :offset, 0)
    search = Keyword.get(opts, :search)
    tag = Keyword.get(opts, :tag)

    base_query =
      from(s in Story,
        where: s.project_id == ^scope.active_project.id,
        order_by: [desc: s.updated_at]
      )

    query =
      if search && search != "" do
        search_term = "%#{search}%"

        from(s in base_query,
          where: like(s.title, ^search_term) or like(s.description, ^search_term)
        )
      else
        base_query
      end

    query =
      if tag && tag != "" do
        from(s in query,
          join: st in CodeMySpec.Tags.StoryTag,
          on: st.story_id == s.id,
          join: t in CodeMySpec.Tags.Tag,
          on: t.id == st.tag_id,
          where: t.name == ^tag and t.project_id == ^scope.active_project.id
        )
      else
        query
      end

    total = Repo.aggregate(query, :count, :id)

    stories =
      query
      |> limit(^limit)
      |> offset(^offset)
      |> Repo.all()
      |> Repo.preload([:criteria, :tags])

    {stories, total}
  end

  @doc """
  Lists just story IDs and titles (lightweight, no criteria).
  Useful for quick lookups and selection.
  """
  def list_story_titles(%Scope{} = scope, opts \\ []) do
    search = Keyword.get(opts, :search)

    base_query =
      from(s in Story,
        where: s.project_id == ^scope.active_project.id,
        order_by: [asc: s.title],
        select: %{id: s.id, title: s.title, component_id: s.component_id}
      )

    query =
      if search && search != "" do
        search_term = "%#{search}%"
        from(s in base_query, where: like(s.title, ^search_term))
      else
        base_query
      end

    Repo.all(query)
  end

  def list_project_stories_by_priority(%Scope{} = scope) do
    from(s in Story,
      where: s.project_id == ^scope.active_project.id,
      order_by: [
        asc_nulls_last: s.priority,
        asc: s.title
      ],
      preload: [:criteria, :tags]
    )
    |> Repo.all()
  end

  def list_unsatisfied_stories(%Scope{} = scope) do
    from(s in Story,
      where: s.project_id == ^scope.active_project.id and is_nil(s.component_id)
    )
    |> Repo.all()
  end

  def list_component_stories(%Scope{} = scope, component_id) do
    from(s in Story,
      where: s.component_id == ^component_id and s.project_id == ^scope.active_project_id
    )
    |> Repo.all()
    |> Repo.preload([:criteria, :tags])
  end

  def get_story(%Scope{} = scope, id) do
    case cast_story_id(id) do
      {:ok, story_id} ->
        Story
        |> Repo.get_by(id: story_id, project_id: scope.active_project_id)
        |> Repo.preload([:criteria, :tags])

      :error ->
        nil
    end
  end

  defp cast_story_id(id) when is_integer(id), do: {:ok, id}

  defp cast_story_id(id) when is_binary(id) do
    case Integer.parse(id) do
      {int, ""} -> {:ok, int}
      _ -> :error
    end
  end

  defp cast_story_id(_), do: :error

  def get_story!(%Scope{} = scope, id) do
    Story
    |> Repo.get_by!(id: id, project_id: scope.active_project_id)
    |> Repo.preload([:criteria, :tags])
  end

  def create_story(
        %Scope{active_project: %Project{id: project_id}, active_account: %Account{id: account_id}} =
          scope,
        attrs
      ) do
    attrs_with_ownership = inject_criteria_ownership(attrs, project_id)

    %Story{}
    |> Story.changeset(attrs_with_ownership)
    |> Ecto.Changeset.put_change(:project_id, project_id)
    |> Ecto.Changeset.put_change(:account_id, account_id)
    |> PaperTrail.insert(originator: scope.user)
    |> case do
      {:ok, %{model: story}} -> {:ok, Repo.preload(story, [:criteria, :tags])}
      {:error, changeset} -> {:error, changeset}
    end
  end

  def create_story(%Scope{} = scope, attrs) do
    %Story{}
    |> Story.changeset(attrs)
    |> PaperTrail.insert(originator: scope.user)
    |> case do
      {:ok, %{model: story}} -> {:ok, Repo.preload(story, [:criteria, :tags])}
      {:error, changeset} -> {:error, changeset}
    end
  end

  def update_story(%Scope{} = scope, %Story{} = story, attrs) do
    attrs_with_ownership = inject_criteria_ownership(attrs, story.project_id)

    story
    |> Story.changeset(attrs_with_ownership)
    |> PaperTrail.update(originator: scope.user)
    |> case do
      {:ok, %{model: story}} -> {:ok, Repo.preload(story, [:criteria, :tags], force: true)}
      {:error, changeset} -> {:error, changeset}
    end
  end

  def delete_story(%Scope{} = scope, %Story{} = story) do
    case PaperTrail.delete(story, originator: scope.user) do
      {:ok, %{model: story}} -> {:ok, story}
      {:error, changeset} -> {:error, changeset}
    end
  end

  def by_project(query \\ Story, project_id) do
    from(s in query, where: s.project_id == ^project_id)
  end

  def by_status(query \\ Story, status) do
    from(s in query, where: s.status == ^status)
  end

  def by_priority(query \\ Story, min_priority) do
    from(s in query,
      where: s.priority >= ^min_priority
    )
  end

  def search_text(query \\ Story, text) do
    search_term = "%#{text}%"

    from(s in query,
      where: like(s.title, ^search_term) or like(s.description, ^search_term)
    )
  end

  def locked_by(query \\ Story, user_id) do
    from(s in query, where: s.locked_by == ^user_id)
  end

  def lock_expired(query \\ Story) do
    from(s in query,
      where: not is_nil(s.lock_expires_at) and s.lock_expires_at < ^DateTime.utc_now()
    )
  end

  def ordered_by_priority(query \\ Story) do
    from(s in query, order_by: [asc_nulls_last: s.priority, asc: s.title])
  end

  def ordered_by_name(query \\ Story) do
    from(s in query, order_by: [asc: s.title])
  end

  def ordered_by_status(query \\ Story) do
    from(s in query, order_by: [asc: s.status, asc: s.inserted_at])
  end

  def paginate(query, page, per_page) do
    offset = (page - 1) * per_page
    from(s in query, limit: ^per_page, offset: ^offset)
  end

  def with_preloads(query, preloads) do
    from(s in query, preload: ^preloads)
  end

  def acquire_lock(%Scope{} = scope, %Story{} = story, expires_in_minutes \\ 30) do
    lock_expires_at = DateTime.utc_now() |> DateTime.add(expires_in_minutes * 60, :second)

    attrs = %{
      locked_by: scope.user.id,
      locked_at: DateTime.utc_now(),
      lock_expires_at: lock_expires_at
    }

    case locked?(story) do
      true -> {:error, :already_locked}
      false -> update_lock_fields(story, attrs)
    end
  end

  def release_lock(%Scope{}, %Story{} = story) do
    attrs = %{
      locked_by: nil,
      locked_at: nil,
      lock_expires_at: nil
    }

    update_lock_fields(story, attrs)
  end

  def extend_lock(%Scope{} = scope, %Story{} = story, expires_in_minutes \\ 30) do
    lock_expires_at = DateTime.utc_now() |> DateTime.add(expires_in_minutes * 60, :second)

    case lock_owner(story) == scope.user.id do
      true -> update_lock_fields(story, %{lock_expires_at: lock_expires_at})
      false -> {:error, :not_lock_owner}
    end
  end

  def locked?(%Story{} = story) do
    not is_nil(story.locked_by) and
      not is_nil(story.lock_expires_at) and
      DateTime.compare(story.lock_expires_at, DateTime.utc_now()) == :gt
  end

  def lock_owner(%Story{} = story) do
    story.locked_by
  end

  def set_story_component(%Scope{} = scope, %Story{} = story, component_id) do
    story
    |> Story.changeset(%{component_id: component_id})
    |> PaperTrail.update(originator: scope.user)
    |> case do
      {:ok, %{model: story}} -> {:ok, story}
      {:error, changeset} -> {:error, changeset}
    end
  end

  def clear_story_component(%Scope{} = scope, %Story{} = story) do
    story
    |> Story.changeset(%{component_id: nil})
    |> PaperTrail.update(originator: scope.user)
    |> case do
      {:ok, %{model: story}} -> {:ok, story}
      {:error, changeset} -> {:error, changeset}
    end
  end

  # Private function for lock operations that don't need audit trail
  defp update_lock_fields(%Story{} = story, attrs) do
    story
    |> Story.lock_changeset(attrs)
    |> Repo.update()
  end

  # Injects project_id into criteria attrs before changeset processing
  defp inject_criteria_ownership(attrs, project_id) do
    criteria_key =
      if is_map(attrs) && Map.has_key?(attrs, :criteria), do: :criteria, else: "criteria"

    case get_in_flexible(attrs, criteria_key) do
      nil ->
        attrs

      criteria when is_list(criteria) ->
        updated_criteria =
          Enum.map(criteria, fn criterion ->
            put_flexible(criterion, :project_id, project_id)
          end)

        put_flexible(attrs, criteria_key, updated_criteria)

      criteria when is_map(criteria) ->
        # Handle map format from form params like %{"0" => %{...}, "1" => %{...}}
        updated_criteria =
          Enum.into(criteria, %{}, fn {key, criterion} ->
            {key, put_flexible(criterion, :project_id, project_id)}
          end)

        put_flexible(attrs, criteria_key, updated_criteria)
    end
  end

  defp get_in_flexible(map, key) when is_atom(key),
    do: Map.get(map, key) || Map.get(map, to_string(key))

  defp get_in_flexible(map, key) when is_binary(key),
    do: Map.get(map, key) || Map.get(map, String.to_existing_atom(key))

  defp put_flexible(map, key, value) when is_map(map) do
    # Use atom key if map has atom keys, string key otherwise
    actual_key =
      cond do
        is_struct(map) -> key
        map |> Map.keys() |> Enum.any?(&is_atom/1) -> key
        is_atom(key) -> to_string(key)
        true -> key
      end

    Map.put(map, actual_key, value)
  end
end
