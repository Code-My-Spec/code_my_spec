defmodule CodeMySpec.Requirements.GraphInputs do
  @moduledoc """
  One event, published by everything the requirement graph is computed from.

  ## Why this exists

  Every graph computation in this application is triggered by a *reader* — a
  LiveView rendering, `get_next_requirement`, the stop menu. Nothing computes on
  a write and nothing computes on a schedule, so an agent that is not reading
  never learns that work appeared.

  Watched on 2026-09-07: a product agent stopped correctly with an empty queue —
  "No product work is currently available; I'll stop and wait to be woken when a
  product requirement is unblocked" — and sat for ninety minutes while four
  issues were filed and `issues_triaged` became actionable again.

  Before this there were two proxies for "the graph moved": a task completing,
  and (briefly) an issue being filed. `GraphFingerprint` covers ten inputs. Two
  proxies for ten inputs is a hand-maintained list, and the eight it misses look
  exactly like those ninety minutes.

  ## Why a new topic rather than the ones that exist

  The contexts already broadcast, and they are keyed for the reader they were
  written for: `user:<user_id>:components`, `user:<account_id>:issues`,
  `project:<id>:personas`. A per-project watcher cannot subscribe to a
  user-keyed topic — it does not know which users are going to write.

  So this is one topic per project, published to by every writer whose table the
  fingerprint hashes. Readers keep their own topics; this one exists for the
  watcher and says only "something the graph is computed from moved", never what.

  ## Why the broadcast carries nothing, and the mark does

  The broadcast is still payload-free, for the reason it always was: the
  fingerprint answers "did anything actually change" over every input at once,
  and a payload saying *which* would be a second, worse copy of that.
  `GraphWatcher` debounces these and asks the fingerprint.

  What changed is that the fingerprint is being replaced on the domain half, and
  its replacement needs the answer the broadcast refuses to give. So a writer
  now also names the entities it moved, and those names are written to
  `graph_invalidations` — durable, because an accumulated dirty set cannot be
  rebuilt after a restart the way a derived one can.

  The two coexist on purpose and they are not redundant. The fingerprint is the
  incumbent and still decides; the marks are a second opinion being measured
  against it. When the diff says the marks are at least as good, the
  fingerprints come out of the domain half and the marks decide alone.

  A writer that cannot yet say what it moved passes nothing, and that records a
  project-wide mark. Un-narrowed is a state to be counted, not hidden — a writer
  that named nothing must not look like a writer that stayed silent.

  So a writer that publishes when nothing really changed costs one hash, and a
  writer that is unsure should publish.
  """

  require Logger

  alias CodeMySpec.Requirements.Invalidations
  alias CodeMySpec.Users.Scope

  @pubsub CodeMySpec.PubSub

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

  The three lines every writer needs, in one place. `Issues` carried them
  inline and was the only writer that did; copying that block to each of the
  remaining fingerprint inputs would have been eight copies of a log format
  and an argument order, which is the shape that drifts.

  `source` names the context in the log line — the same `[Issues]` prefix that
  block already wrote — so a burst in the log still says who moved.

  `entities` is what this writer moved, as `{"component", id}` and
  `{"story", id}` — the same shape `RequirementGraph` keys stale entities by, so
  a mark and a fingerprint verdict are directly comparable. Omitted or empty
  means "something moved and this writer cannot say what", which is recorded as
  project-wide rather than dropped.
  """
  @spec announce(Scope.t() | Ecto.UUID.t() | nil, String.t(), [Invalidations.entity()]) :: :ok
  def announce(scope_or_project_id, source, entities \\ []) when is_binary(source) do
    obs = observation_id()
    Logger.info("[#{source}] announcing a graph change", obs: obs)
    Invalidations.record(project_id(scope_or_project_id), source, entities, obs)
    changed(scope_or_project_id, obs)
  end

  defp project_id(%Scope{active_project_id: project_id}), do: project_id
  defp project_id(project_id) when is_binary(project_id), do: project_id
  defp project_id(_no_project), do: nil

  @doc """
  The entities for a writer whose rows hang off one story.

  Criteria, rules, questions and QA attempts are all the same shape:
  `Freshness.story/2` hashes them grouped by `story_id`, the broadcast message
  is `{verb, row}`, and the row carries the id. Four copies of that would be
  four places for the argument order to drift, which is the reason `announce/2`
  exists at all.

  A row with no `story_id` yields nothing to name, which records project-wide —
  correct rather than conservative: such a row is not in any story's fingerprint
  and the writer genuinely cannot say what moved.
  """
  @spec story_entities(term()) :: [Invalidations.entity()]
  def story_entities({_verb, %{story_id: story_id}}) when not is_nil(story_id),
    do: [{"story", story_id}]

  def story_entities(_message), do: []

  @doc """
  Say what happened, rather than that something did.

  The difference between this and `announce/3` is the difference between an
  event and an invalidation. `announce/3` names entities that moved, and a
  consumer can only answer it by recomputing them. This names the domain event
  and carries what a handler needs to write the verdict directly — an issue
  arriving at medium severity *is* `issues_triaged = false`, and there is
  nothing to ask.

  `entities` is still recorded, because a consumer with no handler for this kind
  falls back to invalidating them. So an event is strictly more information than
  a mark, never less, and adding one cannot make a projection wronger than it
  was.
  """
  @spec event(Scope.t() | Ecto.UUID.t() | nil, String.t(), String.t(), map(), [
          Invalidations.entity()
        ]) :: :ok
  def event(scope_or_project_id, source, kind, payload, entities \\ [])
      when is_binary(source) and is_binary(kind) do
    obs = observation_id()
    Logger.info("[#{source}] #{kind}", obs: obs)

    Invalidations.record_event(
      project_id(scope_or_project_id),
      source,
      kind,
      payload,
      entities,
      obs
    )

    changed(scope_or_project_id, obs)
  end

  @doc """
  An id for one observation, so the recompute that consumes it can name it.

  Not a payload, and the distinction is the whole reason this does not
  contradict "Why it carries nothing" above. That paragraph refuses to say
  *which* input moved, because the fingerprint already answers that over every
  input at once and a second answer would drift from the first. This says only
  *that this particular publish* happened, which the fingerprint cannot answer
  at all and never will: it compares states, so it is silent about how many
  observations were folded into the state it is looking at.

  What that silence cost, measured: of eight recomputes in half an hour, three
  could be tied to an issue by hand-comparing timestamps against the database,
  and five had no identifiable cause. Neither the fingerprint nor the counts
  can close that gap — "67 entities stale" is equally consistent with one
  observation and with twenty, and with an observation that arrived and was
  dropped on the floor.

  Short rather than a UUID because it is read in a log line beside nine other
  digests, and four bytes is already more than enough to tell one burst from
  the next.
  """
  @spec observation_id() :: String.t()
  def observation_id, do: Base.encode16(:crypto.strong_rand_bytes(4), case: :lower)

  @doc "Listen for one project's graph-input changes."
  @spec subscribe(Ecto.UUID.t()) :: :ok | {:error, term()}
  def subscribe(project_id) when is_binary(project_id),
    do: Phoenix.PubSub.subscribe(@pubsub, topic(project_id))
end
