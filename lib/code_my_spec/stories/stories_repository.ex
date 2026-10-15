defmodule CodeMySpec.Stories.StoriesRepository do
  @moduledoc false

  import Ecto.Query, warn: false

  alias CodeMySpec.Accounts.Account
  alias CodeMySpec.Projects.Project
  alias CodeMySpec.Repo
  alias CodeMySpec.Stories.Story
  alias CodeMySpec.Users.Scope
  alias CodeMySpec.Users.User

  # PaperTrail originator, or `nil` when there isn't a real one.
  #
  # Local CLI scopes have no user identity, so local work records no
  # originator. PaperTrail must never receive a placeholder id here: an
  # originator id that is not persisted violates `versions_originator_id_fkey`.
  defp originator(%Scope{user: %User{} = user}), do: user
  defp originator(%Scope{}), do: nil

  def list_stories(%Scope{} = scope) do
    scope
    |> active_stories()
    |> Repo.all()
    |> Repo.preload([:criteria, :tags])
  end

  # Retired stories are kept, never listed.
  defp active_stories(%Scope{} = scope) do
    from(s in Story, where: s.project_id == ^scope.active_project.id and is_nil(s.retired_at))
  end

  @doc """
  Ids of stories whose specs-ready latch is set.

  Deliberately narrow: the stop hook calls this on every stop to decide
  which spex failures may block, so it reads `active_project_id` directly
  and skips the `:criteria` / `:tags` preloads the general list functions
  carry.
  """
  def list_specs_ready_story_ids(%Scope{active_project_id: project_id}) do
    Story
    |> where([s], s.project_id == ^project_id and s.specs_ready == true)
    |> select([s], s.id)
    |> Repo.all()
  end

  @doc """
  `%{story_id => %{at: DateTime.t() | nil, commit: String.t() | nil}}` for the
  given story ids.

  Display data for a stop-hook refusal: when and where a `specs_ready` latch
  was earned, so a reader on a different checkout can tell an earned-elsewhere
  latch from a fresh regression. Narrow, because it is on the stop path.
  """
  def specs_ready_stamps(%Scope{active_project_id: project_id}, story_ids)
      when is_list(story_ids) do
    Story
    |> where([s], s.project_id == ^project_id and s.id in ^story_ids)
    |> select([s], {s.id, s.specs_ready_at, s.specs_ready_commit})
    |> Repo.all()
    |> Map.new(fn {id, at, commit} -> {id, %{at: at, commit: commit}} end)
  end

  @doc """
  `%{story_id => number}` for every story in the project.

  What a page needs to label a story by its number, which names its spex
  directory; id and number coincide on a young project and diverge later.
  Narrow: no preloads.
  """
  def story_numbers(%Scope{active_project_id: project_id}) do
    Story
    |> where([s], s.project_id == ^project_id)
    |> select([s], {s.id, s.number})
    |> Repo.all()
    |> Map.new()
  end

  @doc """
  `%{story_id => working_copy_id}` for the project's assigned stories.

  Only the assigned ones; a story missing from this map is in the shared
  backlog.
  """
  def list_story_working_copy_ids(%Scope{active_project_id: project_id}) do
    Story
    |> where([s], s.project_id == ^project_id and not is_nil(s.working_copy_id))
    |> select([s], {s.id, s.working_copy_id})
    |> Repo.all()
    |> Map.new()
  end

  @doc """
  `%{number => id}` for the project's stories.

  Resolves a spex directory name (`test/spex/<n>_<slug>/`, named from the
  number) back to a story id. Never compare a number against ids: it silently
  matches the wrong story.
  """
  def list_story_ids_by_number(%Scope{active_project_id: project_id}) do
    Story
    |> where([s], s.project_id == ^project_id and not is_nil(s.number))
    |> select([s], {s.number, s.id})
    |> Repo.all()
    |> Map.new()
  end

  @doc """
  Every story's working copy, keyed by story id.

  Which checkout owns a story, so a finding about it can be told from a
  finding about somebody else's work. The assignment answers this, not where
  spec files sit: files stay on a copy after its stories move.
  """
  def list_working_copy_ids_by_story(%Scope{active_project_id: project_id}) do
    Story
    |> where([s], s.project_id == ^project_id and not is_nil(s.working_copy_id))
    |> select([s], {s.id, s.working_copy_id})
    |> Repo.all()
    |> Map.new()
  end

  def list_project_stories(%Scope{} = scope) do
    stories =
      scope
      |> active_stories()
      |> Repo.all()
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
    ready_for_dev = Keyword.get(opts, :ready_for_dev)
    without_epic = Keyword.get(opts, :without_epic)
    epic_id = Keyword.get(opts, :epic_id)

    query =
      from(s in Story,
        where: s.project_id == ^scope.active_project.id and is_nil(s.retired_at),
        order_by: [desc: s.updated_at]
      )
      |> filter_by_search(search)
      |> filter_by_tag(tag, scope.active_project.id)
      |> filter_by_readiness(ready_for_dev)
      |> filter_by_epic_membership(without_epic)
      |> filter_by_epic(epic_id)

    total = Repo.aggregate(query, :count, :id)

    stories =
      query
      |> limit(^limit)
      |> offset(^offset)
      |> Repo.all()
      |> Repo.preload([:criteria, :tags])

    {stories, total}
  end

  defp filter_by_search(query, search) when search in [nil, ""], do: query

  defp filter_by_search(query, search) do
    term = "%#{search}%"
    from(s in query, where: like(s.title, ^term) or like(s.description, ^term))
  end

  defp filter_by_tag(query, tag, _project_id) when tag in [nil, ""], do: query

  defp filter_by_tag(query, tag, project_id) do
    from(s in query,
      join: st in CodeMySpec.Tags.StoryTag,
      on: st.story_id == s.id,
      join: t in CodeMySpec.Tags.Tag,
      on: t.id == st.tag_id,
      where: t.name == ^tag and t.project_id == ^project_id
    )
  end

  # The backlog view. This is the only route to stories the development graph
  # deliberately hides, so it must be able to select them. `ready_for_dev` is
  # nullable in the DB; NULL counts as not ready.
  defp filter_by_readiness(query, true), do: from(s in query, where: s.ready_for_dev == true)

  defp filter_by_readiness(query, false),
    do: from(s in query, where: is_nil(s.ready_for_dev) or s.ready_for_dev == false)

  defp filter_by_readiness(query, _), do: query

  # `without_epic: true`: which stories sit outside every epic.
  defp filter_by_epic_membership(query, true), do: from(s in query, where: is_nil(s.epic_id))
  defp filter_by_epic_membership(query, false), do: from(s in query, where: not is_nil(s.epic_id))
  defp filter_by_epic_membership(query, _), do: query

  # One named epic's stories (`list_epics` reports only a count). Slug or id,
  # since `list_epics` prints both; the UUID cast decides, because comparing a
  # slug against `s.epic_id` is a cast error, not an empty result.
  defp filter_by_epic(query, epic) when epic in [nil, ""], do: query

  defp filter_by_epic(query, epic) do
    case Ecto.UUID.cast(epic) do
      {:ok, id} ->
        from(s in query, where: s.epic_id == ^id)

      :error ->
        from(s in query,
          join: e in CodeMySpec.Epics.Epic,
          on: e.id == s.epic_id,
          where: e.slug == ^epic
        )
    end
  end

  @doc """
  Ready stories that belong to no epic and are not yet promoted: the stories
  that still need dispatching. Ready only, because an unreleased story is not
  yet anybody's problem; unpromoted, because `ready_for_dev` stays set after
  delivery.
  """
  @spec ready_stories_without_epic(Scope.t()) :: [Story.t()]
  def ready_stories_without_epic(%Scope{active_project_id: project_id}) do
    from(s in Story,
      where:
        s.project_id == ^project_id and s.ready_for_dev == true and is_nil(s.epic_id) and
          is_nil(s.promoted_version),
      order_by: [asc: s.inserted_at]
    )
    |> Repo.all()
  end

  @doc """
  Lists just story IDs and titles (lightweight, no criteria).
  Useful for quick lookups and selection.
  """
  def list_story_titles(%Scope{} = scope, opts \\ []) do
    search = Keyword.get(opts, :search)

    base_query =
      from(s in Story,
        where: s.project_id == ^scope.active_project.id and is_nil(s.retired_at),
        order_by: [asc: s.title],
        select: %{id: s.id, number: s.number, title: s.title, component_id: s.component_id}
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
      where: s.project_id == ^scope.active_project.id and is_nil(s.retired_at),
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
      where:
        s.project_id == ^scope.active_project.id and is_nil(s.component_id) and
          is_nil(s.retired_at),
      preload: [:criteria, :tags]
    )
    |> Repo.all()
  end

  def list_component_stories(%Scope{} = scope, component_id) do
    from(s in Story,
      where:
        s.component_id == ^component_id and s.project_id == ^scope.active_project_id and
          is_nil(s.retired_at)
    )
    |> Repo.all()
    |> Repo.preload([:criteria, :tags])
  end

  def get_story(%Scope{} = scope, id) do
    case cast_story_id(id) do
      {:ok, story_id} ->
        Story
        |> Repo.get_by(id: story_id, project_id: scope.active_project_id)
        |> Repo.preload([:criteria, :tags, :component, :epic])

      :error ->
        nil
    end
  end

  def list_certified_on_copy(%Scope{} = scope, working_copy_id) when is_binary(working_copy_id) do
    Story
    |> where(
      [s],
      s.project_id == ^scope.active_project_id and s.working_copy_id == ^working_copy_id and
        not is_nil(s.qa_ready_commit) and is_nil(s.promoted_version)
    )
    |> order_by([s], desc: s.qa_ready_at, asc: s.id)
    |> Repo.all()
  end

  @doc """
  A story by its durable number rather than its id — what a human reads off
  the page and the URL is expected to carry. Scoped to the project: numbers
  are unique per project only.
  """
  def get_story_by_number(%Scope{} = scope, number) do
    case cast_story_id(number) do
      {:ok, story_number} ->
        Story
        |> Repo.get_by(number: story_number, project_id: scope.active_project_id)
        |> Repo.preload([:criteria, :tags, :component, :epic])

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

  @doc "Bang counterpart to `get_story_by_number/2`."
  def get_story_by_number!(%Scope{} = scope, number) do
    Story
    |> Repo.get_by!(number: number, project_id: scope.active_project_id)
    |> Repo.preload([:criteria, :tags, :component, :epic])
  end

  def create_story(%Scope{active_project: %Project{id: project_id}} = scope, attrs) do
    attrs_with_ownership = inject_criteria_ownership(attrs, project_id)

    %Story{}
    |> Story.changeset(attrs_with_ownership)
    |> Story.retire_dropped_criteria()
    |> Ecto.Changeset.put_change(:project_id, project_id)
    |> put_account_id(scope)
    |> put_number(project_id)
    |> PaperTrail.insert(originator: originator(scope))
    |> case do
      {:ok, %{model: story}} -> {:ok, Repo.preload(story, [:criteria, :tags])}
      {:error, changeset} -> {:error, changeset}
    end
  end

  # A story's durable name, minted above the highest already in the project
  # (not the per-deployment `id`), so a number is never reused. An explicitly
  # supplied number wins, which is how migration keeps a story's name.
  defp put_number(changeset, project_id) do
    case Ecto.Changeset.get_field(changeset, :number) do
      nil -> Ecto.Changeset.put_change(changeset, :number, next_number(project_id))
      _ -> changeset
    end
  end

  # One above the highest in the project. Not a counter on `projects`, which
  # row-locked the project on every insert. Stories are never deleted, so the
  # max is never freed; the unique index on `(project_id, number)` catches a
  # concurrent collision.
  defp next_number(project_id) do
    from(s in Story, where: s.project_id == ^project_id, select: max(s.number))
    |> Repo.one()
    |> case do
      nil -> 1
      max -> max + 1
    end
  end

  defp put_account_id(changeset, %Scope{active_account: %Account{id: id}}),
    do: Ecto.Changeset.put_change(changeset, :account_id, id)

  defp put_account_id(changeset, %Scope{active_account_id: id}) when not is_nil(id),
    do: Ecto.Changeset.put_change(changeset, :account_id, id)

  defp put_account_id(changeset, _), do: changeset

  def update_story(%Scope{} = scope, %Story{} = story, attrs) do
    attrs_with_ownership = inject_criteria_ownership(attrs, story.project_id)

    story
    |> Story.changeset(attrs_with_ownership)
    |> Story.retire_dropped_criteria()
    |> PaperTrail.update(originator: originator(scope))
    |> case do
      {:ok, %{model: story}} -> {:ok, Repo.preload(story, [:criteria, :tags], force: true)}
      {:error, changeset} -> {:error, changeset}
    end
  end

  # Retired, never deleted: the story keeps its row and number, leaves the
  # backlog and the graph (a parked story produces no requirements), and its
  # criteria retire with it. Linked issues keep their story reference.
  def retire_story(%Scope{} = scope, %Story{} = story) do
    now = DateTime.utc_now()

    Repo.transaction(fn ->
      from(c in CodeMySpec.Stories.AcceptanceCriteria.Criterion,
        where: c.story_id == ^story.id and is_nil(c.retired_at)
      )
      |> Repo.update_all(set: [retired_at: now])

      story
      |> Ecto.Changeset.change(retired_at: now, ready_for_dev: false)
      |> PaperTrail.update(originator: originator(scope))
      |> case do
        {:ok, %{model: model}} -> model
        {:error, changeset} -> Repo.rollback(changeset)
      end
    end)
  end

  # Back under its number, with the criteria that were retired with it —
  # the ones stamped at the same instant. Criteria retired on their own
  # before the story stay retired. The story comes back parked: releasing it
  # again is its own decision.
  def restore_story(%Scope{} = scope, %Story{retired_at: %DateTime{} = retired_at} = story) do
    Repo.transaction(fn ->
      from(c in CodeMySpec.Stories.AcceptanceCriteria.Criterion,
        where: c.story_id == ^story.id and c.retired_at == ^retired_at
      )
      |> Repo.update_all(set: [retired_at: nil])

      story
      |> Ecto.Changeset.change(retired_at: nil)
      |> PaperTrail.update(originator: originator(scope))
      |> case do
        {:ok, %{model: model}} -> model
        {:error, changeset} -> Repo.rollback(changeset)
      end
    end)
  end

  def restore_story(_scope, %Story{}), do: {:error, :not_retired}

  def by_project(query \\ Story, project_id) do
    from(s in query, where: s.project_id == ^project_id)
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

    if locked?(story), do: {:error, :already_locked}, else: update_lock_fields(story, attrs)
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

    if lock_owner(story) == scope.user.id,
      do: update_lock_fields(story, %{lock_expires_at: lock_expires_at}),
      else: {:error, :not_lock_owner}
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
    |> PaperTrail.update(originator: originator(scope))
    |> case do
      {:ok, %{model: story}} -> {:ok, story}
      {:error, changeset} -> {:error, changeset}
    end
  end

  # All-or-nothing: any not_found / unauthorized / invalid changeset rolls back
  # the whole batch. Callers (notably proposal execution) treat the proposal as
  # one atomic design — partial application is worse than failing loudly,
  # because it leaves the DB straddling two designs.
  def bulk_set_story_component(%Scope{} = scope, links) when is_list(links) do
    story_ids = Enum.map(links, & &1.story_id)
    account_id = scope_account_id(scope)

    Repo.transaction(fn ->
      stories = load_stories_by_id(story_ids)
      Enum.map(links, &apply_link(&1, stories, account_id, scope))
    end)
  end

  defp load_stories_by_id(story_ids) do
    Story
    |> where([s], s.id in ^story_ids)
    |> Repo.all()
    |> Map.new(&{&1.id, &1})
  end

  defp apply_link(%{story_id: story_id, component_id: component_id}, stories, account_id, scope) do
    story = Map.get(stories, story_id) || Repo.rollback({:not_found, story_id})

    if account_id && story.account_id && story.account_id != account_id do
      Repo.rollback({:unauthorized, story_id})
    end

    story
    |> Story.changeset(%{component_id: component_id})
    |> PaperTrail.update(originator: originator(scope))
    |> case do
      {:ok, %{model: updated}} -> updated
      {:error, changeset} -> Repo.rollback({:invalid, story_id, changeset})
    end
  end

  defp scope_account_id(%Scope{active_account: %{id: id}}), do: id
  defp scope_account_id(%Scope{active_account_id: id}), do: id

  def clear_story_component(%Scope{} = scope, %Story{} = story) do
    story
    |> Story.changeset(%{component_id: nil})
    |> PaperTrail.update(originator: originator(scope))
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

  @doc """
  Release these stories' reservations on this copy.

  A team switching or clearing its story frees the old one for another copy to
  take; without it a copy pins every story it was ever pointed at. The caller
  leaves out whatever an agent on the copy still holds.
  """
  @spec release_stories(Scope.t(), Ecto.UUID.t(), [integer()]) :: non_neg_integer()
  def release_stories(_scope, _copy_id, []), do: 0

  def release_stories(%Scope{} = scope, copy_id, story_ids) do
    {count, _} =
      Story
      |> where([s], s.working_copy_id == ^copy_id and s.id in ^story_ids)
      |> where([s], s.project_id == ^scope.active_project_id)
      |> where([s], s.account_id == ^scope.active_account_id)
      |> Repo.update_all(set: [working_copy_id: nil])

    count
  end

  @doc """
  Reserve a story for a checkout so work on it can be selected there: ready for
  development, and unassigned or already this checkout's. An unassigned story
  is assigned here. Locks the story row, so call it inside the transaction
  that records the selection.
  """
  @spec reserve_story(Scope.t(), Ecto.UUID.t(), term()) ::
          {:ok, Story.t()} | {:error, :not_found | :story_not_ready | :story_assigned_elsewhere}
  def reserve_story(%Scope{} = scope, copy_id, story_id) do
    with {:ok, id} <- Ecto.Type.cast(:id, story_id),
         %Story{} = story <-
           Story
           |> where([s], s.id == ^id and s.project_id == ^scope.active_project_id)
           |> where([s], s.account_id == ^scope.active_account_id)
           |> lock("FOR UPDATE")
           |> Repo.one() do
      cond do
        not story.ready_for_dev ->
          {:error, :story_not_ready}

        story.working_copy_id not in [nil, copy_id] ->
          {:error, :story_assigned_elsewhere}

        is_nil(story.working_copy_id) ->
          story |> Story.changeset(%{working_copy_id: copy_id}) |> Repo.update()

        true ->
          {:ok, story}
      end
    else
      _ -> {:error, :not_found}
    end
  end
end
