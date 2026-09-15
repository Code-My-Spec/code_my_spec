defmodule CodeMySpec.Notifications do
  @moduledoc """
  Context for managing push notification subscriptions and sending Web Push notifications.
  """

  use Boundary,
    top_level?: true,
    deps: [
      CodeMySpec.Agents,
      CodeMySpec.Auth,
      CodeMySpec.Conversations,
      CodeMySpec.Repo,
      CodeMySpec.Users,
      CodeMySpec.Utils
    ],
    exports: :all

  require Logger

  import Ecto.Query

  alias CodeMySpec.Notifications.PermissionRequest
  alias CodeMySpec.Notifications.PushSubscription
  alias CodeMySpec.Notifications.QuestionRequest
  alias CodeMySpec.Repo
  alias CodeMySpec.Utils.MapAccess

  @doc """
  Subscribe a user to push notifications.

  Upserts on endpoint — if the same browser endpoint already exists,
  updates the keys.
  """
  def subscribe(user_id, %{} = subscription_params) do
    attrs = Map.put(subscription_params, "user_id", user_id)

    %PushSubscription{}
    |> PushSubscription.changeset(attrs)
    |> Repo.insert(
      on_conflict: {:replace, [:p256dh_key, :auth_key, :updated_at]},
      conflict_target: :endpoint
    )
  end

  @doc """
  Remove a push subscription by endpoint.
  """
  def unsubscribe(endpoint) when is_binary(endpoint) do
    query = from(s in PushSubscription, where: s.endpoint == ^endpoint)

    case Repo.delete_all(query) do
      {count, _} -> {:ok, count}
    end
  end

  @doc """
  Send a push notification to all subscriptions for a user.

  Fire-and-forget: errors are logged but not raised. Expired subscriptions
  (404/410 from push service) are automatically cleaned up.
  """
  def notify_user(user_id, %{} = payload) do
    subscriptions =
      from(s in PushSubscription, where: s.user_id == ^user_id)
      |> Repo.all()

    if subscriptions == [] do
      Logger.debug("[Notifications] No subscribers for user #{user_id}")
      :ok
    else
      Logger.info(
        "[Notifications] Sending push to #{length(subscriptions)} subscriber(s) for user #{user_id}"
      )

      message = Jason.encode!(payload)

      Enum.each(subscriptions, fn sub ->
        send_push(sub, message)
      end)

      :ok
    end
  end

  # --- Notifications inbox ---

  @resolved_limit 50

  @doc """
  List a user's question and permission requests for the notifications inbox.

  Pending items first (newest first), then the #{@resolved_limit} most recently
  resolved items across both types.
  """
  def list_notifications(user_id) do
    pending_notifications(user_id) ++ resolved_notifications(user_id)
  end

  @doc """
  Pending question and permission requests for the inbox, newest first.

  Never paginated: there is no history to page through, only the (usually
  small) set of things still waiting on an answer.
  """
  def list_pending_notifications(user_id) do
    pending_notifications(user_id)
  end

  @doc """
  One page of resolved question and permission requests, newest first.

  `:before` asks for the page older than a given position, so the inbox can
  load more as the user scrolls. `:limit` defaults to #{@resolved_limit}.

  Merges two schemas by `inserted_at` rather than querying one after the
  other: fetching `limit` candidates from *each* and merging guarantees the
  true top `limit` combined, since neither schema alone can contribute more
  than `limit` rows to any top-`limit` result.

  `:before` is `{inserted_at, seen_ids}`, not a bare timestamp. Both schemas
  store `inserted_at` at `:utc_datetime` (second) precision, so two requests
  landing in the same second — ordinary on a box running several agents at
  once — tie, and a bare `< inserted_at` cursor would silently drop whichever
  one fell on the older side of that split. `seen_ids` names every row
  already shown at the boundary second so the next page's tie-break is
  `inserted_at == before and id not in seen_ids` instead.
  """
  def list_resolved_notifications(user_id, opts \\ []) do
    limit = Keyword.get(opts, :limit, @resolved_limit)
    before = Keyword.get(opts, :before)

    ((resolved_page_query(QuestionRequest, user_id, limit, before) |> Repo.all()) ++
       (resolved_page_query(PermissionRequest, user_id, limit, before) |> Repo.all()))
    |> Enum.sort(&newest_first/2)
    |> Enum.take(limit)
  end

  @doc "Count a user's pending question and permission requests."
  def count_pending_notifications(user_id) do
    count_pending(QuestionRequest, user_id) + count_pending(PermissionRequest, user_id)
  end

  @doc """
  Subscribe to the badge topic: `{:pending_notifications_changed}` fires whenever
  a request is created or resolved. Consumed (halted) by the layout badge hook.
  """
  def subscribe_notifications(user_id) do
    Phoenix.PubSub.subscribe(CodeMySpec.PubSub, "user_notifications:#{user_id}")
  end

  @doc """
  Subscribe to the list topic: `{:notifications_changed}` fires on the same
  events. Separate topic so the inbox LiveView receives it even though the
  badge hook halts its own message.
  """
  def subscribe_notifications_list(user_id) do
    Phoenix.PubSub.subscribe(CodeMySpec.PubSub, "user_notifications:#{user_id}:list")
  end

  defp broadcast_notifications_changed(user_id) do
    Phoenix.PubSub.broadcast(
      CodeMySpec.PubSub,
      "user_notifications:#{user_id}",
      {:pending_notifications_changed}
    )

    Phoenix.PubSub.broadcast(
      CodeMySpec.PubSub,
      "user_notifications:#{user_id}:list",
      {:notifications_changed}
    )
  end

  defp pending_notifications(user_id) do
    ((pending_query(QuestionRequest, user_id) |> Repo.all()) ++
       (pending_query(PermissionRequest, user_id) |> Repo.all()))
    |> Enum.sort_by(& &1.inserted_at, {:desc, DateTime})
  end

  defp resolved_notifications(user_id) do
    ((resolved_query(QuestionRequest, user_id) |> Repo.all()) ++
       (resolved_query(PermissionRequest, user_id) |> Repo.all()))
    |> Enum.sort_by(& &1.inserted_at, {:desc, DateTime})
    |> Enum.take(@resolved_limit)
  end

  defp pending_query(schema, user_id) do
    from(r in schema,
      where: r.user_id == ^user_id and r.status == "pending",
      order_by: [desc: r.inserted_at]
    )
  end

  defp resolved_query(schema, user_id) do
    from(r in schema,
      where: r.user_id == ^user_id and r.status != "pending",
      order_by: [desc: r.inserted_at],
      limit: @resolved_limit
    )
  end

  defp resolved_page_query(schema, user_id, limit, before) do
    from(r in schema,
      where: r.user_id == ^user_id and r.status != "pending",
      order_by: [desc: r.inserted_at, desc: r.id],
      limit: ^limit
    )
    |> before_cursor(before)
  end

  # `inserted_at` alone is not a total order at `:utc_datetime` precision —
  # see `list_resolved_notifications/2`'s doc — so every place that orders by
  # it for pagination breaks ties on `id` too, database query and in-memory
  # merge alike, or the two would disagree about which of a tied pair comes
  # first.
  defp newest_first(a, b) do
    case DateTime.compare(a.inserted_at, b.inserted_at) do
      :eq -> a.id >= b.id
      :gt -> true
      :lt -> false
    end
  end

  defp before_cursor(query, nil), do: query

  defp before_cursor(query, {%DateTime{} = before, seen_ids}) do
    where(
      query,
      [r],
      r.inserted_at < ^before or (r.inserted_at == ^before and r.id not in ^seen_ids)
    )
  end

  defp count_pending(schema, user_id) do
    from(r in schema, where: r.user_id == ^user_id and r.status == "pending")
    |> Repo.aggregate(:count)
  end

  # --- Permission Requests ---

  @doc """
  Create a permission request and notify the user via Web Push.

  Returns `{:ok, permission_request}` on success.
  The caller should then subscribe to PubSub topic
  `"permission_request:<id>"` to await the decision.
  """
  def create_permission_request(user_id, %{} = attrs) do
    attrs = Map.merge(attrs, %{"user_id" => user_id, "status" => "pending"})

    result =
      %PermissionRequest{}
      |> PermissionRequest.changeset(attrs)
      |> Repo.insert()

    case result do
      {:ok, request} ->
        # Send Web Push notification to the user
        notify_user(user_id, %{
          type: "permission_request",
          title: "Claude Code: #{request.tool_name}",
          body: format_tool_summary(request.tool_name, request.tool_input),
          url: permission_url(request)
        })

        broadcast_notifications_changed(user_id)

        {:ok, request}

      error ->
        error
    end
  end

  @doc """
  Resolve a permission request with a decision (allow/deny).

  Broadcasts the decision on PubSub so the waiting SSE connection receives it.
  """
  def resolve_permission_request(id, decision) when decision in ~w(allow deny) do
    case Repo.get(PermissionRequest, id) do
      nil ->
        {:error, :not_found}

      %{status: "pending"} = request ->
        request
        |> PermissionRequest.changeset(%{
          status: decision_to_status(decision),
          decision: decision
        })
        |> Repo.update()
        |> case do
          {:ok, updated} ->
            Phoenix.PubSub.broadcast(
              CodeMySpec.PubSub,
              "permission_request:#{id}",
              {:permission_decided, %{id: id, decision: decision}}
            )

            broadcast_notifications_changed(updated.user_id)
            deliver_decision_to_agent(updated)

            {:ok, updated}

          error ->
            error
        end

      %{status: status} ->
        {:error, {:already_resolved, status}}
    end
  end

  @doc """
  Clear a pending permission request without a decision.

  Not what `resolve_permission_request/2` is for — that records a human's
  actual allow/deny. This is a human's *other* choice: the request no longer
  matters, and no one is going to look at it. Marks the row `"expired"`
  rather than `"denied"` so the notifications list can tell "nobody decided"
  apart from "somebody said no", and still delivers the same "keep going" a
  decline would to any agent that happens to still be alive — silence would
  otherwise look identical to a decision nobody has made yet.

  Unlike `QuestionRequest` (deliberately answer-only — story 896: a question
  disappearing on its own is a choice the user never made vanishing from the
  one place they would have seen it), this is a human looking at the request
  and choosing to clear it, one row or many, not a clock sweeping it away.
  """
  @spec dismiss_permission_request(Ecto.UUID.t()) ::
          {:ok, PermissionRequest.t()} | {:error, term()}
  def dismiss_permission_request(id) do
    case Repo.get(PermissionRequest, id) do
      nil ->
        {:error, :not_found}

      %{status: "pending"} = request ->
        request
        |> PermissionRequest.changeset(%{status: "expired"})
        |> Repo.update()
        |> case do
          {:ok, updated} ->
            Phoenix.PubSub.broadcast(
              CodeMySpec.PubSub,
              "permission_request:#{id}",
              {:permission_decided, %{id: id, decision: :expired}}
            )

            broadcast_notifications_changed(updated.user_id)
            deliver_decision_to_agent(updated)

            {:ok, updated}

          error ->
            error
        end

      %{status: status} ->
        {:error, {:already_resolved, status}}
    end
  end

  @doc """
  Dismiss many of a user's own pending permission requests at once.

  Returns the count actually dismissed. An id that does not belong to
  `user_id`, or is not (or no longer) pending, is silently skipped rather
  than failing the whole batch — the list this reads from is itself a
  snapshot, and a request resolved by its own SSE connection a moment
  earlier is not a bug in the bulk action that missed it.
  """
  @spec bulk_dismiss_permission_requests([Ecto.UUID.t()], integer()) :: non_neg_integer()
  def bulk_dismiss_permission_requests(ids, user_id) when is_list(ids) do
    PermissionRequest
    |> where([p], p.id in ^ids and p.user_id == ^user_id and p.status == "pending")
    |> select([p], p.id)
    |> Repo.all()
    |> Enum.reduce(0, fn id, count ->
      case dismiss_permission_request(id) do
        {:ok, _} -> count + 1
        _ -> count
      end
    end)
  end

  # Tell the agent what was decided.
  #
  # A Claude Code request is answered on the SSE connection already waiting on
  # it — that is what `permission_request:<id>` is broadcast for. An agent we
  # run has no such connection: it asked, it stopped, and the decision reaches
  # it as a message or not at all.
  #
  # Denied is the case that matters. Approved and the loop ends, which the agent
  # will notice by not being asked to continue; denied and it must keep going,
  # and an agent that asked to leave and heard nothing has no way to tell a
  # refusal from a decision nobody has made yet.
  defp deliver_decision_to_agent(%{agent_id: nil}), do: :ok

  defp deliver_decision_to_agent(%{agent_id: agent_id} = request) do
    # An approved tap-out ends the loop, and saying so is not ending it. The
    # message told the agent "the loop is done" while `continuous` stayed set,
    # so the next stop woke it again — permission to leave, followed by being
    # asked to carry on.
    #
    # Before the message, so the agent cannot be woken between the two.
    if tap_out_approved?(request), do: CodeMySpec.Agents.leave_loop(agent_id)

    _ = CodeMySpec.Agents.send_to_agent(agent_id, decision_message(request))
    :ok
  end

  defp tap_out_approved?(%{tool_name: "tap_out", decision: "allow"}), do: true
  defp tap_out_approved?(_request), do: false

  defp decision_message(%{tool_name: "tap_out", decision: "allow"}) do
    """
    Your tap-out was approved. The loop is done — finish what is in front of you
    and stop. Nothing will ask you to continue.
    """
  end

  defp decision_message(%{tool_name: "tap_out", status: "expired"}) do
    """
    Your tap-out request expired — nobody decided it either way. Keep going.

    Pick the work back up where you left it. Ask again if you are still stuck.
    """
  end

  defp decision_message(%{tool_name: "tap_out"}) do
    """
    Your tap-out was declined. Keep going.

    Pick the work back up where you left it. If you asked because you were stuck
    rather than because you were finished, say what is blocking you — a second
    identical request will be declined the same way.
    """
  end

  defp decision_message(%{tool_name: tool, decision: "allow"}),
    do: "Your request to use `#{tool}` was approved. Go ahead."

  defp decision_message(%{tool_name: tool}),
    do: "Your request to use `#{tool}` was declined. Do not retry it; find another way."

  @doc """
  Get a permission request by ID.
  """
  def get_permission_request(id), do: Repo.get(PermissionRequest, id)

  @doc """
  The permission/tap-out requests one agent raised, oldest first.

  The permission-request spelling of `list_question_requests_for_agent/1`, for
  the same reason a conversation needs it: an agent's own transcript shows the
  agent's own requests, and the lookup is by agent id because an agent we run
  has no session for a request to live on.
  """
  @spec list_permission_requests_for_agent(Ecto.UUID.t() | nil) :: [PermissionRequest.t()]
  def list_permission_requests_for_agent(nil), do: []

  def list_permission_requests_for_agent(agent_id) when is_binary(agent_id) do
    PermissionRequest
    |> where([p], p.agent_id == ^agent_id)
    |> order_by([p], asc: p.inserted_at)
    |> Repo.all()
  end

  @doc """
  The agent's own pending tap-out request, if it already has one.

  `request_agent_tap_out/2`'s caller must not create a second row while the
  first is undecided — an agent asks once and is told to stop, not to ask
  again, but `wake_project_roles/2`'s missing guard (fixed alongside this)
  handed it a menu with `tap_out` still offered on every unrelated project
  change while one was already pending, and each call created a fresh row.
  Measured live: 224 pending tap-out requests behind ten agents, one of them
  holding 129 — the tool creating a duplicate on every retry, not a human
  answering slowly.
  """
  @spec get_pending_tap_out_request(Ecto.UUID.t()) :: PermissionRequest.t() | nil
  def get_pending_tap_out_request(agent_id) when is_binary(agent_id) do
    PermissionRequest
    |> where([p], p.agent_id == ^agent_id and p.tool_name == "tap_out" and p.status == "pending")
    |> Repo.one()
  end

  # --- Question Requests (remote AskUserQuestion) ---

  @doc """
  Create a question request and notify the user via Web Push.

  Returns `{:ok, question_request}`. The caller subscribes to PubSub topic
  `"question_request:<id>"` to await the answer.
  """
  def create_question_request(user_id, %{} = attrs) do
    attrs =
      attrs
      |> Map.merge(%{"user_id" => user_id, "status" => "pending"})
      |> put_anchor()

    with {:ok, request} <-
           %QuestionRequest{} |> QuestionRequest.changeset(attrs) |> Repo.insert() do
      notify_user(user_id, %{
        type: "question_request",
        title: request.title || "Claude Code has a question",
        body: first_question_text(request.questions),
        url: question_url(request)
      })

      broadcast_notifications_changed(user_id)

      {:ok, request}
    end
  end

  @doc """
  Record answers to a question request and broadcast them so the waiting hook
  receives them. `answers` maps each question's text to the chosen label(s).

  `answered_by` defaults to `"user"` — every existing caller (`QuestionLive`,
  the conversation page, `QuestionController`) is a person answering, and
  `MainAgent.settle/4` is the one caller that overrides it.

  ## Overruling, and only in this one direction

  A request the main agent already answered can be answered again by the
  user — that is criterion 3220's whole point, and without it a main agent's
  wrong answer buries the question forever: `%{status: "answered"}` reads as
  finished by every ordinary rule, and the user has no route back to it. The
  new answer replaces the old outright rather than merging with it, and
  `overruled` is set so the collecting agent is told an earlier answer
  existed rather than reading this as an ordinary first answer.

  Every other repeat is still refused. A user's answer is the one that
  stands (3219), so a main agent may never overwrite it, and a user
  correcting their own answer a second time is not a case any surface
  offers — `ChatComponents.question/1` drops the form once a user has
  answered.
  """
  def answer_question_request(id, %{} = answers, opts \\ []) do
    answered_by = Keyword.get(opts, :answered_by, "user")

    case Repo.get(QuestionRequest, id) do
      nil ->
        {:error, :not_found}

      %{status: "pending"} = request ->
        finish(request, answers, answered_by, false)

      %{status: "answered", answered_by: "main_agent"} = request when answered_by == "user" ->
        finish(request, answers, answered_by, true)

      %{status: status} ->
        {:error, {:already_resolved, status}}
    end
  end

  defp finish(request, answers, answered_by, overruled) do
    request
    |> QuestionRequest.changeset(%{
      status: "answered",
      answers: answers,
      answered_by: answered_by,
      overruled: overruled
    })
    |> Repo.update()
    |> case do
      {:ok, updated} ->
        Phoenix.PubSub.broadcast(
          CodeMySpec.PubSub,
          "question_request:#{updated.id}",
          {:question_answered, %{id: updated.id, answers: answers}}
        )

        broadcast_notifications_changed(updated.user_id)
        deliver_to_agent(updated)

        {:ok, updated}

      error ->
        error
    end
  end

  # Hand the answer back to the agent that asked.
  #
  # Here rather than at the three call sites — `QuestionLive`, the conversation
  # page, and `QuestionController` — because a delivery each caller has to
  # remember is one that will be missed by whichever route is added next, and
  # the symptom is an agent that stopped and never woke up. There is nothing to
  # decide per caller: the question knows who asked.
  #
  # Nil `agent_id` is the ordinary case for a Claude Code session, which polls
  # with `check_answer` and has no process of ours to message.
  #
  # Result deliberately dropped. The answer is recorded whether or not the
  # agent's machine is reachable, and failing the person's submission because an
  # agent went away would lose the answer to save the notification.
  defp deliver_to_agent(%{agent_id: nil}), do: :ok

  defp deliver_to_agent(%{agent_id: agent_id} = request) do
    _ = CodeMySpec.Agents.send_to_agent(agent_id, answer_message(request))
    :ok
  end

  # What the agent is handed. Self-contained on purpose: it asked, stopped, and
  # is being woken by this — so the question has to come back with the answer or
  # the agent is reading a reply to something it cannot see.
  defp answer_message(%{questions: questions, answers: answers}) do
    body =
      Enum.map_join(questions, "\n\n", fn question ->
        text = MapAccess.get(question, :question)
        "Q: #{text}\nA: #{said(answers, text)}"
      end)

    """
    The user answered your question.

    #{body}

    Carry on from there. If this settles what you were blocked on, finish the
    task and close it out.
    """
  end

  defp said(answers, text) do
    case answers[text] || answers[to_string(text)] do
      nil -> "(no answer recorded)"
      list when is_list(list) -> Enum.join(list, ", ")
      value -> to_string(value)
    end
  end

  # Where tapping the notification lands you.
  #
  # `QuestionLive.Show` exists because an *external* agent has no conversation
  # in this application to render a question into — that is the whole of its
  # reason, and it is still true for Claude Code and false for an agent we run.
  # So the rule is: the question belongs in the asker's conversation, and the
  # standalone page is the fallback for an asker that has not got one.
  #
  # Anchored to the question itself, so the page opens with it in view rather
  # than at the bottom of a fifty-turn transcript.
  defp question_url(%{agent_id: agent_id, id: id}) when is_binary(agent_id) do
    case conversation_for_agent(agent_id) do
      %{id: conversation_id, project_id: project_id} ->
        "/app/projects/#{project_id}/agent-conversation?conversation=#{conversation_id}#question-#{id}"

      _ ->
        "/app/questions/#{id}"
    end
  end

  defp question_url(%{id: id}), do: "/app/questions/#{id}"

  # Same rule as `question_url/1`, for the request an agent raised rather than
  # asked. No `conversation_message_id` exists on a permission request — there
  # is no schema for "what turn this happened at" — so the anchor is the
  # request itself rather than a specific point in the transcript; it renders
  # unconditionally near the bottom of it either way.
  defp permission_url(%{agent_id: agent_id, id: id}) when is_binary(agent_id) do
    case conversation_for_agent(agent_id) do
      %{id: conversation_id, project_id: project_id} ->
        "/app/projects/#{project_id}/agent-conversation?conversation=#{conversation_id}#permission-#{id}"

      _ ->
        "/app/permissions/#{id}"
    end
  end

  defp permission_url(%{id: id}), do: "/app/permissions/#{id}"

  defp conversation_for_agent(agent_id) do
    from(c in CodeMySpec.Conversations.Conversation,
      where: c.agent_id == ^agent_id,
      order_by: [desc: c.inserted_at],
      limit: 1
    )
    |> Repo.one()
  end

  # Where in the transcript this question was asked.
  #
  # The newest message in the asking agent's conversation, resolved now rather
  # than plumbed through MCP: a tool does not know its own tool-call id, and it
  # does not need to — it only needs to know which conversation it is in, which
  # the agent id answers.
  #
  # Worst case it anchors to the turn *before* the one that asked, if that
  # turn's message has not been written yet. That is still beside the work that
  # prompted it, which is the whole point, and strictly better than the pinned
  # block it replaces.
  #
  # A caller that set it explicitly wins. Nil is left alone — a Claude Code
  # session has no conversation of ours and renders on `QuestionLive.Show`.
  defp put_anchor(%{"conversation_message_id" => id} = attrs) when not is_nil(id), do: attrs

  defp put_anchor(attrs) do
    case attrs["agent_id"] do
      agent_id when is_binary(agent_id) ->
        Map.put(attrs, "conversation_message_id", newest_message_id(agent_id))

      _ ->
        attrs
    end
  end

  defp newest_message_id(agent_id) do
    from(m in CodeMySpec.Conversations.Message,
      join: c in assoc(m, :conversation),
      where: c.agent_id == ^agent_id,
      order_by: [desc: m.inserted_at],
      limit: 1,
      select: m.id
    )
    |> Repo.one()
  end

  @doc """
  Is this agent waiting on a human before it should be bothered?

  Asked on every stop decision, which is why the index is on
  `(agent_id, status)` rather than on `agent_id` alone.

  Two tables, one question. `ask_user_question` writes a `QuestionRequest`;
  `tap_out`, called by an agent we run, writes a `PermissionRequest` with the
  same `agent_id` (`McpServers.Tasks.Tools.TapOut.request_agent_tap_out/2`) —
  `TapOut.request/2`'s session-keyed `session.state["pending_tap_out"]` is a
  different mechanism entirely, for a Claude Code session rather than an
  agent, and `Hooks.Stop` checks that one directly.

  This started covering only `QuestionRequest`, and `StopDecision.wake/2` had
  no check of either at all — `wake_project_roles/2` fans out to every
  continuous, running agent on any graph change project-wide, with nothing
  asking whether the agent it is about to wake asked to stop. An agent with a
  tap-out pending got "Work of your kind is available" every time anything
  else in the project changed, at whatever cadence that happens on a shared
  project several worktrees are editing at once — sometimes under a minute
  apart — and had to spend a turn saying "still waiting" each time. Both
  decision points call this now, so a widened definition here reaches both
  without either drifting from the other.
  """
  @spec awaiting_answer?(Ecto.UUID.t() | nil) :: boolean()
  def awaiting_answer?(nil), do: false

  def awaiting_answer?(agent_id) when is_binary(agent_id) do
    pending_question?(agent_id) or pending_permission?(agent_id)
  end

  defp pending_question?(agent_id) do
    QuestionRequest
    |> where([q], q.agent_id == ^agent_id and q.status == "pending")
    |> Repo.exists?()
  end

  defp pending_permission?(agent_id) do
    PermissionRequest
    |> where([p], p.agent_id == ^agent_id and p.status == "pending")
    |> Repo.exists?()
  end

  @doc "Get a question request by ID."
  def get_question_request(id), do: Repo.get(QuestionRequest, id)

  @doc """
  Every question asked during one Claude session, oldest first.

  What a transcript needs: the questions belong in the conversation they came
  out of, so the reader answers with the work that prompted them in view.
  """
  @spec list_question_requests_for_session(String.t() | nil) :: [QuestionRequest.t()]
  def list_question_requests_for_session(nil), do: []

  def list_question_requests_for_session(session_external_id) do
    QuestionRequest
    |> where([q], q.session_external_id == ^session_external_id)
    |> order_by([q], asc: q.inserted_at)
    |> Repo.all()
  end

  @doc """
  The questions one agent asked, oldest first.

  Not the agent-shaped spelling of `list_question_requests_for_session/1` — a
  different abstraction that happens to answer a similar-looking question. A
  session is a Claude Code process with an external id; an agent is a row we
  own. Neither has the other, and a question belongs to exactly one of them.

  This is why the conversation page could not show a question an agent asked.
  It looked them up by `session_external_id`, and an agent has none: the asking
  scope carries a working copy and never a session id, so the column stayed
  empty and the lookup found nothing. The tool call rendered as an ordinary
  tool block with no form under it — nothing wrong with the rendering, the page
  was asking the wrong question.
  """
  @spec list_question_requests_for_agent(Ecto.UUID.t() | nil) :: [QuestionRequest.t()]
  def list_question_requests_for_agent(nil), do: []

  def list_question_requests_for_agent(agent_id) when is_binary(agent_id) do
    QuestionRequest
    |> where([q], q.agent_id == ^agent_id)
    |> order_by([q], asc: q.inserted_at)
    |> Repo.all()
  end

  @doc """
  Every question this user has waiting, whichever session asked it.

  Separate from `list_question_requests_for_session/1` because the two answer
  different questions and only one of them is about a conversation. A thread
  shows what *that* agent asked; the project's own screen has to show what any
  agent asked, because an agent in a worktree nobody is watching is exactly the
  one whose question goes unnoticed.

  Pending only. An answered request is history, and history does not block
  anybody.
  """
  @spec list_pending_question_requests_for_user(integer()) :: [QuestionRequest.t()]
  def list_pending_question_requests_for_user(user_id) when is_integer(user_id) do
    QuestionRequest
    |> where([q], q.user_id == ^user_id and q.status == "pending")
    |> order_by([q], asc: q.inserted_at)
    |> Repo.all()
  end

  @doc """
  Turn a submitted form into `%{question text => answer}`.

  Lives here rather than in a LiveView because two of them submit this shape
  now — the question's own page and the conversation it was asked in — and the
  "__other__" convention is a property of the form the component renders, not
  of either host.
  """
  @spec collect_answers([map()], map()) :: map()
  def collect_answers(questions, params) do
    questions
    |> Enum.with_index()
    |> Map.new(fn {question, i} ->
      {question["question"], resolve_answer(params["q_#{i}"], params["q_#{i}_other"])}
    end)
  end

  defp resolve_answer(choices, other) when is_list(choices) do
    Enum.map(choices, fn c -> if c == "__other__", do: other || "", else: c end)
  end

  defp resolve_answer("__other__", other), do: other || ""
  defp resolve_answer(choice, _other) when is_binary(choice), do: choice
  defp resolve_answer(_choice, _other), do: ""

  defp first_question_text([%{"question" => q} | _]) when is_binary(q), do: q
  defp first_question_text(_), do: "Tap to answer"

  defp decision_to_status("allow"), do: "approved"
  defp decision_to_status("deny"), do: "denied"

  defp format_tool_summary("Bash", %{"command" => cmd}), do: cmd
  defp format_tool_summary("Read", %{"file_path" => path}), do: path
  defp format_tool_summary("Write", %{"file_path" => path}), do: path
  defp format_tool_summary("Edit", %{"file_path" => path}), do: path
  defp format_tool_summary(_tool, input), do: Jason.encode!(input)

  defp send_push(subscription, message) do
    push_subscription =
      Jason.encode!(%{
        endpoint: subscription.endpoint,
        keys: %{
          p256dh: subscription.p256dh_key,
          auth: subscription.auth_key
        }
      })

    case WebPushElixir.send_notification(push_subscription, message) do
      {:ok, _response} ->
        :ok

      {:error, :expired} ->
        Logger.info("[Notifications] Subscription expired, removing: #{subscription.endpoint}")

        Repo.delete(subscription)

      {:error, {:http_error, status, _body}} when status in [404, 410] ->
        Logger.info(
          "[Notifications] Subscription gone (#{status}), removing: #{subscription.endpoint}"
        )

        Repo.delete(subscription)

      {:error, reason} ->
        Logger.warning(
          "[Notifications] Failed to send push to #{subscription.endpoint}: #{inspect(reason)}"
        )
    end
  end
end
