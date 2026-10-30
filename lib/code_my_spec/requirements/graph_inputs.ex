defmodule CodeMySpec.Requirements.GraphInputs do
  @moduledoc """
  One event, published by everything the requirement graph is computed from.

  Every writer whose rows the graph reads announces here: the write is recorded
  as a durable mark (`Invalidations`) naming the entities it moved, and a
  payload-free `{:graph_inputs_changed, project_id, obs}` goes out on one topic
  per project. `IncrementalGraph` drains on it; LiveViews refresh on it.

  A writer that cannot say what it moved names nothing, which records a
  project-wide mark rather than nothing. A writer that is unsure should
  publish.

  A leaf boundary, depending only on `Invalidations` and `Scope`: every context
  the graph reads publishes here, so any wider dependency would cycle them
  through the graph.

  See knowledge/requirements_graph/checkers, "Announcing writes".
  """

  use Boundary,
    top_level?: true,
    deps: [CodeMySpec.Requirements.Invalidations, CodeMySpec.Users.Scope]

  require Logger

  alias CodeMySpec.Requirements.Invalidations
  alias CodeMySpec.Users.Scope

  @pubsub CodeMySpec.PubSub

  @typedoc "One of the declared kinds. See `kinds/0`."
  @type kind :: String.t()

  # Every kind that can move the graph. `event/6` refuses any other, and
  # `every_declared_event_is_applied_or_counted_test` asks each for a handler or
  # an explicit fallback. Ordered by the writer that emits it.
  @kinds ~w(
    story_created
    story_changed
    story_deleted
    story_readiness_changed
    issue_created
    issue_accepted
    issue_dismissed
    issue_resolved
    issue_updated
    issue_changed
    component_created
    component_changed
    component_deleted
    dependency_changed
    files_synced
    deploy_changed
    devops_setup_changed
    qa_attempt_submitted
  )

  # What a harness's read model holds (components, stories, criteria): a change
  # to one is told to the project's harnesses, so an overlay does not wait for
  # their next refresh.
  @read_model_kinds ~w(story_created story_changed story_deleted story_readiness_changed
    component_created component_changed component_deleted)
  @read_model_sources ~w(AcceptanceCriteria ComponentSync)

  @doc "Every declared event kind."
  @spec kinds() :: [kind()]
  def kinds, do: @kinds

  @doc """
  Whether an announcement of this shape would be accepted, without making one.

  The check `event/6` raises on: an undeclared kind, or a vantage that is not
  `:project_wide` / `:this_checkout`. `:ok`, or `{:error, message}` carrying the
  explanation the raise would.
  """
  @spec check(term(), term()) :: :ok | {:error, String.t()}
  def check(kind, vantage)

  def check(kind, _vantage) when not is_binary(kind) or kind not in @kinds do
    {:error,
     """
     #{inspect(kind)} is not a declared graph event.

     Add it to `GraphInputs.kinds/0`, then either give it a handler in
     `Handlers` or add it to the falls-back list in
     `every_declared_event_is_applied_or_counted_test`. An undeclared kind
     would be recorded as a mark nothing knows how to apply and silently cost
     a recompute on every occurrence.
     """}
  end

  def check(_kind, vantage) when vantage not in [:project_wide, :this_checkout] do
    {:error,
     """
     #{inspect(vantage)} does not say whose answers this change moves.

     A verdict is a statement about one checkout, so an observation has to say
     which checkout's answers it moves or the projector cannot route it.
     `:this_checkout` for a change about the tree the writer is speaking from —
     files synced, an analyzer run. `:project_wide` for one every checkout reads
     — a story renamed, an issue filed.

     Not defaulted, because the two cannot be told apart from the ambient scope:
     an agent renaming a story has an active checkout and the rename is not
     about it. Inheriting would narrow that rename to the agent's own worktree
     and leave every other one carrying the old title.
     """}
  end

  def check(_kind, _vantage), do: :ok

  @doc "Topic for changes to what one project's harnesses hold as their read model."
  @spec read_model_topic(Ecto.UUID.t()) :: String.t()
  def read_model_topic(project_id) when is_binary(project_id),
    do: "project:#{project_id}:read_model"

  defp read_model_changed(scope_or_project_id) do
    case project_id(scope_or_project_id) do
      nil ->
        :ok

      project_id ->
        Phoenix.PubSub.broadcast(
          @pubsub,
          read_model_topic(project_id),
          {:read_model_changed, project_id}
        )
    end
  end

  @doc "Topic for one project's graph-input changes."
  @spec topic(Ecto.UUID.t()) :: String.t()
  def topic(project_id) when is_binary(project_id), do: "project:#{project_id}:graph_inputs"

  @doc """
  Say that something the graph is computed from has changed.

  Takes a scope so a writer can call it with what it already has. A scope with
  no active project is a no-op rather than an error: plenty of writes happen
  outside a project, and a writer should not have to ask.
  """
  @spec changed(Scope.t() | Ecto.UUID.t() | nil, String.t() | nil) :: :ok
  def changed(scope_or_project_id, observation_id \\ nil)

  def changed(%Scope{active_project_id: project_id}, obs), do: changed(project_id, obs)

  def changed(project_id, obs) when is_binary(project_id) do
    Phoenix.PubSub.broadcast(
      @pubsub,
      topic(project_id),
      {:graph_inputs_changed, project_id, obs}
    )

    :ok
  end

  def changed(_no_project, _obs), do: :ok

  @doc """
  Mint an observation, say so in the log, and publish it.

  `source` names the context in the log line (`[Issues]`), so a burst in the
  log says who moved.

  `entities` is what this writer moved, as `{"component", id}` and
  `{"story", id}`. Empty means "something moved and this writer cannot say
  what", recorded as project-wide rather than dropped.
  """
  @spec announce(Scope.t() | Ecto.UUID.t() | nil, String.t(), [Invalidations.entity()], vantage()) ::
          :ok
  def announce(scope_or_project_id, source, entities, vantage)
      when is_binary(source) and vantage in [:project_wide, :this_checkout] do
    obs = observation_id()
    Logger.info("[#{source}] announcing a graph change", obs: obs)

    Invalidations.record(
      project_id(scope_or_project_id),
      source,
      entities,
      obs,
      working_copy_id(scope_or_project_id, vantage)
    )

    if source in @read_model_sources, do: read_model_changed(scope_or_project_id)
    changed(scope_or_project_id, obs)
  end

  @typedoc """
  Whose answers this write moves.

  Whose answers this write moves. A verdict is a statement about one checkout.

  `:this_checkout`: the change is about the tree the writer speaks from (files
  synced, an analyzer run, a component re-derived from a tree). `:project_wide`:
  every checkout reads it (a story renamed, an issue filed) and it settles all
  of them.

  Declared by the writer, never taken from the scope: an agent renaming a story
  has an active checkout, and the rename is not about it. When unsure, fan out.
  """
  @type vantage :: :project_wide | :this_checkout

  defp working_copy_id(%Scope{active_working_copy_id: copy}, :this_checkout), do: copy
  defp working_copy_id(_scope, _vantage), do: nil

  defp project_id(%Scope{active_project_id: project_id}), do: project_id
  defp project_id(project_id) when is_binary(project_id), do: project_id
  defp project_id(_no_project), do: nil

  @doc """
  The entities for a writer whose rows hang off one story.

  Criteria, rules, questions and QA attempts broadcast `{verb, row}` with the
  row's `story_id`. A row with no `story_id` names nothing, which records
  project-wide.
  """
  @spec story_entities(term()) :: [Invalidations.entity()]
  def story_entities({_verb, %{story_id: story_id}}) when not is_nil(story_id),
    do: [{"story", story_id}]

  def story_entities(_message), do: []

  @doc """
  Say what happened, rather than that something did.

  `announce/4` names entities that moved, answerable only by recomputing them.
  This names the domain event and carries what a handler needs to write the
  verdict directly. `entities` is still recorded, so a kind with no handler
  falls back to recomputing them: an event is never less than a mark.

  Raises `ArgumentError` when `check/2` refuses.
  """
  @spec event(
          Scope.t() | Ecto.UUID.t() | nil,
          String.t(),
          String.t(),
          map(),
          [Invalidations.entity()],
          vantage()
        ) :: :ok
  def event(scope_or_project_id, source, kind, payload, entities, vantage)
      when is_binary(source) and is_binary(kind) do
    case check(kind, vantage) do
      :ok -> :ok
      {:error, message} -> raise ArgumentError, message
    end

    obs = observation_id()
    Logger.info("[#{source}] #{kind}", obs: obs)

    Invalidations.record_event(
      project_id(scope_or_project_id),
      source,
      kind,
      payload,
      entities,
      obs,
      working_copy_id(scope_or_project_id, vantage)
    )

    if kind in @read_model_kinds, do: read_model_changed(scope_or_project_id)
    changed(scope_or_project_id, obs)
  end

  @doc """
  An id for one observation, so the log lines of the write and the drain that
  consumed it can be tied together. Four bytes: read in log lines, and enough
  to tell one burst from the next.
  """
  @spec observation_id() :: String.t()
  def observation_id, do: Base.encode16(:crypto.strong_rand_bytes(4), case: :lower)

  @doc "Listen for changes to what one project's harnesses hold as their read model."
  @spec subscribe_read_model(Ecto.UUID.t()) :: :ok | {:error, term()}
  def subscribe_read_model(project_id) when is_binary(project_id),
    do: Phoenix.PubSub.subscribe(@pubsub, read_model_topic(project_id))

  @doc "Listen for one project's graph-input changes."
  @spec subscribe(Ecto.UUID.t()) :: :ok | {:error, term()}
  def subscribe(project_id) when is_binary(project_id),
    do: Phoenix.PubSub.subscribe(@pubsub, topic(project_id))
end
