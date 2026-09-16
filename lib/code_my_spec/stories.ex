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
      CodeMySpec.AcceptanceCriteria,
      CodeMySpec.Accounts,
      CodeMySpec.Components,
      CodeMySpec.Epics,
      CodeMySpec.Issues,
      CodeMySpec.Projects,
      CodeMySpec.Repo,
      CodeMySpec.Requirements,
      CodeMySpec.Tags,
      CodeMySpec.Users,
      CodeMySpec.WorkingCopies
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

  # Guarded on the id, not the loaded struct, because the id is the only thing
  # below that is read — the topic is built from `active_account_id` and
  # `GraphInputs.announce/2` wants `active_project_id`.
  #
  # It guarded on `active_account` and cost criterion 7942. `PortableHost`
  # rebuilds the scope for the local endpoint with both ids set and the account
  # struct unloaded, so every write through a story LiveView there took this
  # clause: the row changed, the graph was never told, and nothing said so.
  # Invisible until reads stopped recomputing, because until then the next read
  # rebuilt the graph anyway and covered for it.
  defp broadcast(%Scope{active_account_id: nil} = _scope, _message), do: :ok

  defp broadcast(%Scope{} = scope, message) do
    Phoenix.PubSub.broadcast(
      CodeMySpec.PubSub,
      "user:#{scope.active_account_id}:stories",
      message
    )

    GraphInputs.announce(scope, "Stories", graph_entities(message))
  end

  # The story, and the project.
  #
  # Only the story, as far as story requirements go: a story's `component_id` is
  # an edge input — it is in `Freshness.topology_parts/2`, not in
  # `Freshness.component/2` — so attaching a story to a component moves the
  # graph's shape and not that component's own requirements. Topology is
  # fingerprinted separately and is not what these marks replace.
  #
  # `:project` because three project requirements read stories: `stories_exist`,
  # `work_dispatched` through `EpicDispatch.dispatch_state/1`, and
  # `architecture_designed`, which reports stories that are ready and unlinked.
  # A writer that names entities is asserting it moved nothing the project
  # requirements read, and this one would be asserting something false.
  defp graph_entities({_verb, %{id: id}}) when not is_nil(id), do: [{"story", id}, :project]
  defp graph_entities(_message), do: []

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
  `%{story_id => number}` for the project — what a page needs to label a story
  by the number that names its spex directory rather than by its id (1ab62ffd).
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
  A story by its durable number rather than its id (1ab62ffd) — what the URL
  and the UI show a human, since the id and the number coincide on a young
  project and diverge later.
  """
  def get_story_by_number(scope, number), do: impl().get_story_by_number(scope, number)
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
  Ready stories that belong to no epic.

  The reading story 1058 came from: a product agent asked to group ready stories
  into an epic worked out that one sat outside every one of them, could not name
  it, and stopped. Nothing exposed this — `list_epics` lists epics and
  `assign_story_to_epic` writes one, and neither answers a question about
  absence.

  Ready rather than all, because that is the question people ask. A story
  nobody has released is not yet anybody's problem, and including them buries
  the one that is.
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

    with {:ok, story = %Story{}} <- impl().update_story(scope, story, attrs) do
      broadcast(scope, {:updated, story})
      {:ok, story}
    end
  end

  @doc """
  Sets or clears the story's specs-ready latch.

  The latch is what `bdd_specs_passing` checks and what the stop hook
  consults before letting a spex failure block. Three callers write it:
  the specs-passing gate sets it on a fresh green run, the chain-restart
  path clears it when the story's BDD specs are rewritten, and the user
  flips it by hand from the project UI.

  Deliberately narrower than `update_story/3` — the latch carries
  enforcement consequences, so the write path is named rather than
  buried in a generic attrs map.
  """
  def set_specs_ready(%Scope{} = scope, %Story{} = story, ready?) when is_boolean(ready?) do
    update_story(scope, story, %{specs_ready: ready?})
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
    true = story.account_id == scope.active_account_id

    with {:ok, story = %Story{}} <- impl().delete_story(scope, story) do
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
  Stamps every story in this project that has reached `code_on_running_copy`
  but has not yet been promoted, with the version a promotion just
  originated.

  "Reached" means `specs_ready`: `code_on_running_copy`'s own prerequisite is
  `bdd_specs_passing`, so a story with specs not yet green cannot be the
  subject of the question this stamp answers. Not scoped to a working copy —
  `stories.working_copy_id` is set only by epic dispatch and is nil for
  ordinary work, and `code_on_running_copy` never checked it either: the
  check it replaces answered from whichever copy asked, the same answer for
  every qualifying story in the project. This keeps that shape and only
  changes when the answer is taken — once, at promotion, instead of live on
  every read — which is what stops a checkout dirtied afterward for
  unrelated work from un-answering a question that already had its answer.

  The only writer of `promoted_version`. Called once, from
  `CodeMySpec.Promotion`, after a merge into main has already landed. Already
  a `nil` promoted_version is required — a promoted story keeps the version
  it was actually promoted at rather than being bumped to whatever a later,
  unrelated promotion happens to originate.
  """
  def mark_ready_stories_promoted(%Scope{} = scope, version) when is_binary(version) do
    with {:ok, stories} <- impl().mark_ready_stories_promoted(scope, version) do
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
