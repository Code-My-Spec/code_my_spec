defmodule CodeMySpec.Stories do
  @moduledoc """
  The Stories context.

  Direct-DB implementation via `StoriesRepository`. The
  `:stories_implementation` config key is kept as a swap point for test
  doubles.
  """

  use Boundary,
    top_level?: true,
    deps: [
      CodeMySpec.Accounts,
      CodeMySpec.Projects,
      CodeMySpec.Repo,
      CodeMySpec.Requirements.GraphInputs,
      CodeMySpec.Users,
      CodeMySpec.Users.Scope
    ],
    exports: :all

  alias CodeMySpec.Requirements.GraphInputs
  alias CodeMySpec.Stories.StoriesRepository
  alias CodeMySpec.Stories.Story
  alias CodeMySpec.Users.Scope

  defp impl do
    Application.get_env(:code_my_spec, :stories_implementation, StoriesRepository)
  end

  @doc """
  Subscribes to scoped notifications about any story changes.

  The broadcasted messages match the pattern:

    * {:created, %Story{}}
    * {:updated, %Story{}}
    * {:deleted, %Story{}}

  """
  def subscribe_stories(%Scope{} = scope) do
    key = scope.active_account_id

    Phoenix.PubSub.subscribe(CodeMySpec.PubSub, "user:#{key}:stories")
  end

  # Guarded on the id, not the loaded account struct: only ids are read below,
  # and some scopes (the local endpoint's) carry ids with the struct unloaded.
  # A guard on the struct silently skipped the graph announcement.
  defp broadcast(scope, message, kind \\ nil)

  defp broadcast(%Scope{active_account_id: nil} = _scope, _message, _kind), do: :ok

  defp broadcast(%Scope{} = scope, message, kind) do
    Phoenix.PubSub.broadcast(
      CodeMySpec.PubSub,
      "user:#{scope.active_account_id}:stories",
      message
    )

    GraphInputs.event(
      scope,
      "Stories",
      kind || story_event_kind(message),
      %{},
      graph_entities(message),
      # A story is not a checkout's, so a rename made from inside a worktree
      # still moves what every checkout answers about it.
      :project_wide
    )
  end

  # Creation and deletion emit kinds nothing handles: handlers settle rows and
  # never create or reap them, so the entity must go through
  # `compute_entity/4`.
  # See knowledge/requirements_graph/checkers, "Announcing writes".
  defp story_event_kind({:created, _}), do: "story_created"
  defp story_event_kind({:deleted, _}), do: "story_deleted"
  defp story_event_kind(_message), do: "story_changed"

  # A `ready_for_dev` flip is creation or deletion to the graph (`Preloader`
  # projects only ready stories), so it too is a kind nothing handles. Only
  # `update_story/3` can move it.
  defp readiness_kind(%Story{ready_for_dev: same}, %Story{ready_for_dev: same}), do: nil
  defp readiness_kind(_before, _after), do: "story_readiness_changed"

  # The story, and the project. Not the component: a story's `component_id` is
  # an edge input (`Freshness.topology_parts/2`), not one of the component's.
  # `:project` because `stories_exist`, `work_dispatched` and
  # `architecture_designed` read stories.
  defp graph_entities({_verb, %{id: id}}) when not is_nil(id), do: [{"story", id}, :project]
  defp graph_entities(_message), do: []

  @doc "Release these stories' reservations on this copy. See `StoriesRepository.release_stories/3`."
  @spec release_stories(Scope.t(), Ecto.UUID.t(), [integer()]) :: non_neg_integer()
  def release_stories(scope, copy_id, story_ids),
    do: StoriesRepository.release_stories(scope, copy_id, story_ids)

  @doc "Reserve a story for a checkout. See `StoriesRepository.reserve_story/3`."
  @spec reserve_story(Scope.t(), Ecto.UUID.t(), term()) ::
          {:ok, Story.t()} | {:error, :not_found | :story_not_ready | :story_assigned_elsewhere}
  def reserve_story(scope, copy_id, story_id),
    do: StoriesRepository.reserve_story(scope, copy_id, story_id)

  @doc """
  Returns the list of stories.

  ## Examples

      iex> list_stories(scope)
      [%Story{}, ...]

  """
  def list_stories(scope), do: impl().list_stories(scope)
  def list_project_stories(scope), do: impl().list_project_stories(scope)

  @doc """
  Ids of stories whose specs-ready latch is set. Used by the stop hook to
  decide which spex failures are allowed to block.
  """
  def list_specs_ready_story_ids(scope), do: impl().list_specs_ready_story_ids(scope)

  @doc """
  `%{story_id => %{at: DateTime.t() | nil, commit: String.t() | nil}}` for the
  given story ids — when and where each one's `specs_ready` latch was earned.
  Display data only, for a stop-hook refusal on a different checkout; never
  checked back for ancestry.
  """
  def specs_ready_stamps(scope, story_ids), do: impl().specs_ready_stamps(scope, story_ids)

  @doc """
  `%{story_id => number}` for the project — what a page needs to label a story
  by the number that names its spex directory rather than by its id.
  """
  def story_numbers(scope), do: impl().story_numbers(scope)

  @doc """
  `%{story_id => working_copy_id}` for stories assigned to a checkout.

  Absent means unassigned — the shared backlog every working copy can see.
  """
  def list_story_working_copy_ids(scope), do: impl().list_story_working_copy_ids(scope)

  @doc """
  `%{number => id}` for the project's stories — resolves a spex
  directory name back to the story that owns it.
  """
  def list_story_ids_by_number(scope), do: impl().list_story_ids_by_number(scope)

  @doc "Which working copy owns each story."
  def list_working_copy_ids_by_story(scope), do: impl().list_working_copy_ids_by_story(scope)
  def project_has_stories?(scope), do: impl().project_has_stories?(scope)

  @doc """
  Lists stories with pagination and optional search.
  Returns {stories, total_count}.

  Options:
  - :limit - max stories to return (default: 20)
  - :offset - stories to skip (default: 0)
  - :search - text to filter by title/description
  """
  def list_project_stories_paginated(scope, opts \\ []),
    do: impl().list_project_stories_paginated(scope, opts)

  @doc """
  Lists just story IDs and titles (lightweight, no criteria).
  Returns list of %{id, title, component_id}.

  Options:
  - :search - text to filter by title
  """
  def list_story_titles(scope, opts \\ []),
    do: impl().list_story_titles(scope, opts)

  def list_project_stories_by_priority(scope),
    do: impl().list_project_stories_by_priority(scope)

  def list_unsatisfied_stories(scope), do: impl().list_unsatisfied_stories(scope)

  def list_component_stories(scope, component_id),
    do: impl().list_component_stories(scope, component_id)

  @doc """
  Gets a single story.

  Raises `Ecto.NoResultsError` if the Story does not exist.

  ## Examples

      iex> get_story!(123)
      %Story{}

      iex> get_story!(456)
      ** (Ecto.NoResultsError)

  """
  def get_story!(scope, id), do: impl().get_story!(scope, id)
  def get_story(scope, id), do: impl().get_story(scope, id)

  @doc """
  A story by its durable number rather than its id — what the URL
  and the UI show a human, since the id and the number coincide on a young
  project and diverge later.
  """
  def get_story_by_number(scope, number), do: impl().get_story_by_number(scope, number)

  @doc "Unpromoted stories assigned to `working_copy_id` and certified ready for QA, newest first."
  def list_certified_on_copy(scope, working_copy_id),
    do: impl().list_certified_on_copy(scope, working_copy_id)

  def get_story_by_number!(scope, number), do: impl().get_story_by_number!(scope, number)

  @doc """
  Creates a story.

  ## Examples

      iex> create_story(%{field: value})
      {:ok, %Story{}}

      iex> create_story(%{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  def create_story(%Scope{} = scope, attrs) do
    with {:ok, story = %Story{}} <- impl().create_story(scope, attrs) do
      broadcast(scope, {:created, story})
      {:ok, story}
    end
  end

  @doc """
  Ready stories that belong to no epic — the absence `list_epics` cannot
  answer. Ready only: an unreleased story is not yet anybody's problem.
  """
  @spec ready_stories_without_epic(Scope.t()) :: [Story.t()]
  defdelegate ready_stories_without_epic(scope), to: StoriesRepository

  @doc """
  Updates a story.

  ## Examples

      iex> update_story(story, %{field: new_value})
      {:ok, %Story{}}

      iex> update_story(story, %{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  def update_story(%Scope{} = scope, %Story{} = story, attrs) do
    true = story.account_id == scope.active_account_id

    with {:ok, updated = %Story{}} <- impl().update_story(scope, story, attrs) do
      broadcast(scope, {:updated, updated}, readiness_kind(story, updated))
      {:ok, updated}
    end
  end

  @doc """
  Sets or clears the story's specs-ready latch.

  The latch is what the stop hook consults before letting a spex failure
  block (`Validation.check_blocking_problems/5` — a working copy's own
  in-progress check). The promote gate does not: every red spex refuses
  promotion regardless of latch — this flag no longer exempts anything
  there, only here. Only a promote of the story sets it
  (`mark_story_promoted/4`); rewriting the story's BDD specs, editing its
  criteria, and the story page's Unenforce clear it.

  Clearing also clears the ready-for-QA stamp (`set_qa_ready/4`): the events
  that unlatch a story are the ones that make its certified commit no longer
  answer for it, and one write path keeps the two from drifting.

  Deliberately narrower than `update_story/3` — the latch carries
  enforcement consequences, so the write path is named rather than
  buried in a generic attrs map.

  `opts` on a `true` write: `:at` and `:commit` (display data, so a stop hook
  on a different checkout can say when and where this was earned) and the
  promotion stamps `mark_story_promoted/4` passes. Ignored when `ready?` is
  `false`, which clears the stamps itself.
  """
  def set_specs_ready(scope, story, ready?, opts \\ [])

  def set_specs_ready(%Scope{} = scope, %Story{} = story, true, opts) do
    attrs =
      %{specs_ready: true}
      |> maybe_put(:specs_ready_at, Keyword.get(opts, :at))
      |> maybe_put(:specs_ready_commit, Keyword.get(opts, :commit))
      |> maybe_put(:promoted_version, Keyword.get(opts, :promoted_version))
      |> maybe_put(:promoted_working_copy_id, Keyword.get(opts, :promoted_working_copy_id))
      |> maybe_put(:promoted_at, Keyword.get(opts, :promoted_at))

    update_story(scope, story, attrs)
  end

  def set_specs_ready(%Scope{} = scope, %Story{} = story, false, _opts) do
    update_story(scope, story, %{
      specs_ready: false,
      specs_ready_at: nil,
      specs_ready_commit: nil,
      qa_ready_commit: nil,
      qa_ready_at: nil,
      qa_reviewed_commit: nil,
      qa_reviewed_at: nil
    })
  end

  @doc """
  Stamps `story` ready for QA at `commit` — the commit `Promotion.certify/3`
  passed at. The only writer of `qa_ready_commit`; `ready_for_qa` reads it.
  Cleared by `set_specs_ready(scope, story, false)` and `release_qa_ready/3`.

  `reviewed` is `{commit, at}`: the certification a QA pass must have
  reviewed. This one, unless certification carried an earlier one forward
  because nothing QA exercises changed since (`Qa.StoryReviews.carry/3`).
  """
  @spec set_qa_ready(
          Scope.t(),
          Story.t(),
          String.t(),
          DateTime.t(),
          {String.t() | nil, DateTime.t() | nil} | nil
        ) :: {:ok, Story.t()} | {:error, Ecto.Changeset.t()}
  def set_qa_ready(
        %Scope{} = scope,
        %Story{} = story,
        commit,
        at \\ DateTime.utc_now(),
        reviewed \\ nil
      )
      when is_binary(commit) do
    {reviewed_commit, reviewed_at} = reviewed || {commit, at}

    update_story(scope, story, %{
      qa_ready_commit: commit,
      qa_ready_at: at,
      qa_reviewed_commit: reviewed_commit,
      qa_reviewed_at: reviewed_at
    })
  end

  @doc """
  Takes back a stamp the story's branch has moved past, so the graph offers
  `ready_for_qa` again. `keep_reviewed?` keeps the certification its current QA
  pass reviewed, for certification at the new commit to carry forward when
  nothing QA exercises changed; false forgets it, so QA runs again.
  """
  @spec release_qa_ready(Scope.t(), Story.t(), boolean()) ::
          {:ok, Story.t()} | {:error, Ecto.Changeset.t()}
  def release_qa_ready(%Scope{} = scope, %Story{} = story, keep_reviewed?) do
    attrs = %{qa_ready_commit: nil, qa_ready_at: nil}

    attrs =
      if keep_reviewed?,
        do: attrs,
        else: Map.merge(attrs, %{qa_reviewed_commit: nil, qa_reviewed_at: nil})

    update_story(scope, story, attrs)
  end

  @doc """
  Latches `story`'s specs and stamps it with the version its promote carried
  onto main, in one write.

  The only writer of `promoted_version`. Called from `CodeMySpec.Promotion`
  once a promote named this story, its spex passed on the promoting copy's
  certifying run, and the merge landed. No other story is touched.

  A story already stamped keeps its version: the promote that first carried
  it is the answer to "which promotion put this on main". `nil` (no version
  to stamp) latches without stamping. `opts` are `:at`, `:commit`, and
  `:working_copy_id`. Promotion team and time survive assignment cleanup.
  """
  def mark_story_promoted(%Scope{} = scope, %Story{} = story, version, opts \\ []) do
    stamp = story.promoted_version || version
    opts = Keyword.put(opts, :promoted_version, stamp)

    opts =
      if stamp do
        opts
        |> Keyword.put(
          :promoted_working_copy_id,
          story.promoted_working_copy_id ||
            Keyword.get(opts, :working_copy_id) || story.working_copy_id ||
            scope.active_working_copy_id
        )
        |> Keyword.put(
          :promoted_at,
          story.promoted_at || Keyword.get(opts, :at) || DateTime.utc_now()
        )
      else
        opts
      end

    set_specs_ready(scope, story, true, opts)
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  @doc """
  Retires a story. There is no delete: it keeps its row and number, leaves the
  backlog and the graph, and its criteria retire with it.
  """
  def retire_story(%Scope{} = scope, %Story{} = story) do
    true = story.account_id == scope.active_account_id

    with {:ok, story = %Story{}} <- impl().retire_story(scope, story) do
      broadcast(scope, {:deleted, story})
      {:ok, story}
    end
  end

  @doc """
  Brings a retired story back under its number, with the criteria retired
  with it. It comes back parked.
  """
  def restore_story(%Scope{} = scope, %Story{} = story) do
    true = story.account_id == scope.active_account_id

    with {:ok, story = %Story{}} <- impl().restore_story(scope, story) do
      broadcast(scope, {:updated, story})
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
    active_account_id = scope.active_account_id

    # Local stories pre-dating the account_id backfill have nil account_id;
    # treat that as "unowned" rather than a foreign-account leak.
    case story.account_id do
      nil -> :ok
      ^active_account_id -> :ok
      _ -> raise "story #{story.id} does not belong to the active account"
    end

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

    if account_id && story.account_id && story.account_id != account_id do
      {:error, :unauthorized}
    else
      with {:ok, story = %Story{}} <-
             impl().set_story_component(scope, story, component_id) do
        broadcast(scope, {:updated, story})
        {:ok, story}
      end
    end
  end

  @doc """
  Bulk-assigns components to stories in one round-trip.

  Accepts a list of `%{story_id: id, component_id: id}` maps. All-or-nothing:
  any not_found / unauthorized / invalid changeset rolls back the whole batch.
  Authorization is enforced inside the implementation since stories must be
  loaded server-side anyway.
  """
  def bulk_set_story_component(%Scope{} = scope, links) when is_list(links) do
    with {:ok, stories} <- impl().bulk_set_story_component(scope, links) do
      Enum.each(stories, &broadcast(scope, {:updated, &1}))
      {:ok, stories}
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

    if account_id && story.account_id && story.account_id != account_id do
      {:error, :unauthorized}
    else
      with {:ok, story = %Story{}} <- impl().clear_story_component(scope, story) do
        broadcast(scope, {:updated, story})
        {:ok, story}
      end
    end
  end
end
