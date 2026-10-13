defmodule CodeMySpec.Notifications do
  @moduledoc """
  Context for managing push notification subscriptions and sending Web Push notifications.
  """

  use Boundary,
    top_level?: true,
    deps: [
      CodeMySpec.Agents.Agent,
      CodeMySpec.Auth,
      CodeMySpec.Conversations,
      CodeMySpec.Issues,
      CodeMySpec.Repo,
      CodeMySpec.Sessions,
      CodeMySpec.TaskOwner,
      CodeMySpec.Users.Scope,
      CodeMySpec.Utils
    ],
    exports: :all

  require Logger

  import Ecto.Query

  alias CodeMySpec.Agents.Agent
  alias CodeMySpec.Issues
  alias CodeMySpec.Notifications.PermissionRequest
  alias CodeMySpec.Notifications.PushSubscription
  alias CodeMySpec.Notifications.QuestionRequest
  alias CodeMySpec.Repo
  alias CodeMySpec.Sessions
  alias CodeMySpec.Sessions.Session
  alias CodeMySpec.TaskOwner
  alias CodeMySpec.Users.Scope
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

  # A request whose named asker has stopped is not waiting on anybody.
  #
  # Answering one resumes nothing: `TaskOwner.resume_task/3` has no live agent to
  # resume and the answer reaches no process. It is history, and the inbox was
  # presenting it as work outstanding.
  #
  # Measured 2026-09-23: 41 pending questions held by one user, and NOT ONE had a
  # live asking agent — 35 stopped, 6 with no agent at all. Two questions that
  # day genuinely blocked the Broken Oaths fleet (the grace-window scope on story
  # 947, and story 942 released while marked deferred) and both sat in that list.
  # John: "I cant get them they are hard to find." A queue where nothing is
  # urgent teaches its reader that nothing is urgent, which is the failure that
  # costs time when a real one arrives.
  #
  # `is_nil(agent_id)` is kept, deliberately. `MainAgent.holder_for/2` sends an
  # agentless question to the user by design — "a question with no agent came
  # from Claude Code, which talks to the person directly" — and those are real:
  # among the six were "Story 1020 has 21 rules — how should we cut it" and a
  # dark-mode decision. Absent asker and *departed* asker are different states
  # and only the second one is stale.
  #
  # Hidden from the pending list only. `list_notifications/1` still returns these
  # through `resolved_notifications/1`'s half of the inbox, so nothing is lost —
  # and a stopped agent can come back, since `start_agent/2` now resumes one that
  # still holds work. This is a statement about what is waiting, not about what
  # happened.
  defp pending_query(schema, user_id) do
    from(r in schema,
      where: r.user_id == ^user_id and r.status == "pending",
      where: is_nil(r.agent_id) or r.agent_id not in subquery(stopped_agent_ids()),
      order_by: [desc: r.inserted_at]
    )
    |> held_by_user(schema)
  end

  # Criteria 2075/2076/2123: a question main or product is still holding, or
  # handed to each other, is not the user's to see yet — only `holder ==
  # "user"` rows belong in their inbox. A permission request has no `holder`
  # column; its own visibility to the user is a separate concern this filter
  # leaves untouched.
  defp held_by_user(query, QuestionRequest), do: where(query, [r], r.holder == "user")

  # Criteria 2073/2074 are specifically about a tap-out: everyone else's is
  # main's from the moment it is raised, unless escalated or there is no
  # agent to route through (a Claude Code session tap-out, which is nobody's
  # teammate's and goes straight to the user the way main's own does). Every
  # other permission kind (an ordinary tool-call approval) keeps the behavior
  # this had before 2073/2074 existed: visible to the user immediately,
  # unconditionally.
  defp held_by_user(query, PermissionRequest) do
    where(
      query,
      [r],
      r.tool_name != "tap_out" or not is_nil(r.escalation_reason) or is_nil(r.agent_id) or
        r.agent_id in subquery(main_role_agent_ids())
    )
  end

  defp main_role_agent_ids do
    from(a in Agent, where: a.role == :main, select: a.id)
  end

  # Off or retired: nobody means it to run. An agent on duty whose process is
  # down — restoring, or crashed — is still meant to answer.
  defp stopped_agent_ids do
    from(a in Agent, where: not is_nil(a.off_at) or not is_nil(a.retired_at), select: a.id)
  end

  # Unlike `pending_query`, not filtered by holder: criterion 1197 is exactly
  # this distinction — removing the interruption while main or product holds
  # it is not removing the record once it is resolved, so the user's history
  # always carries what they fielded on their behalf.
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

  # The badge counts what the list shows. Counting every pending row while
  # `pending_query/2` hides the ones whose asker has stopped would put 41 on the
  # badge and six in the inbox, which is worse than either number alone.
  defp count_pending(schema, user_id) do
    schema
    |> pending_query(user_id)
    |> exclude(:order_by)
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
    with {:ok, request} <- insert_permission_request(user_id, attrs) do
      deliver_permission(request)
      {:ok, request}
    end
  end

  defp insert_permission_request(user_id, attrs) do
    attrs = Map.merge(attrs, %{"user_id" => user_id, "status" => "pending"})

    %PermissionRequest{}
    |> PermissionRequest.changeset(attrs)
    |> Repo.insert()
  end

  defp deliver_permission(request) do
    # Send Web Push notification to the user
    notify_user(request.user_id, %{
      type: "permission_request",
      title: "#{request.tool_name} needs your approval",
      body: format_tool_summary(request.tool_name, request.tool_input),
      url: permission_url(request)
    })

    broadcast_notifications_changed(request.user_id)
  end

  @doc "Create one pending tap-out per agent/task intent, blocking linked work atomically."
  def request_agent_tap_out(scope, agent_id, task_id, reason \\ nil),
    do: request_tap_out(scope, Agent, agent_id, task_id, reason)

  @doc """
  The same request for a Claude Code session: a row in the person's inbox,
  whose approval clears `session.continuous` (or cancels the linked task).
  """
  def request_session_tap_out(scope, session_id, task_id, reason \\ nil),
    do: request_tap_out(scope, Session, session_id, task_id, reason)

  defp request_tap_out(scope, owner_schema, owner_id, task_id, reason) do
    owner_key = tap_out_owner_key(owner_schema)

    result =
      Repo.transaction(fn ->
        owner =
          Repo.one(
            from owner in owner_schema,
              where:
                owner.id == ^owner_id and owner.account_id == ^scope.active_account_id and
                  owner.project_id == ^scope.active_project_id,
              lock: "FOR UPDATE"
          )

        if is_nil(owner), do: Repo.rollback(:owner_not_found)

        case pending_tap_out(owner_key, owner_id, task_id) do
          nil ->
            with {:ok, task} <- question_task(owner, task_id),
                 {:ok, request} <-
                   insert_permission_request(scope.user.id, %{
                     Atom.to_string(owner_key) => owner_id,
                     "task_id" => task_id,
                     "tool_name" => "tap_out",
                     "tool_input" => %{"task_id" => task_id, "reason" => reason}
                   }),
                 :ok <- block_tap_out_task(scope, owner, task, request, reason) do
              {request, user_decides?(owner)}
            else
              {:error, error} -> Repo.rollback(error)
            end

          existing ->
            {existing, false}
        end
      end)

    with {:ok, {request, push?}} <- result do
      if push?, do: deliver_permission(request)

      {:ok, request}
    end
  end

  # A teammate's tap-out is the main agent's to decide (criterion 2073), so the
  # person is pushed only for one that is theirs: main's own, or a session's.
  defp user_decides?(%Agent{role: role}), do: role == :main
  defp user_decides?(_session), do: true

  defp tap_out_owner_key(Agent), do: :agent_id
  defp tap_out_owner_key(Session), do: :session_id

  defp pending_tap_out(owner_key, owner_id, task_id) do
    query =
      from p in PermissionRequest,
        where:
          field(p, ^owner_key) == ^owner_id and p.tool_name == "tap_out" and
            p.status == "pending"

    query =
      if is_nil(task_id),
        do: where(query, [p], is_nil(p.task_id)),
        else: where(query, [p], p.task_id == ^task_id)

    Repo.one(query)
  end

  defp block_tap_out_task(_scope, _owner, nil, _request, _reason), do: :ok

  defp block_tap_out_task(scope, owner, task, request, reason) do
    case TaskOwner.block_task(scope, owner, task.id, :tap_out, request.id, reason: reason) do
      {:ok, _owner} -> :ok
      {:error, error} -> {:error, error}
    end
  end

  @doc """
  Resolve a permission request with a decision (allow/deny).

  Broadcasts the decision on PubSub so the waiting SSE connection receives it.
  """
  def resolve_permission_request(id, decision, answer \\ nil)

  def resolve_permission_request(id, decision, answer) when decision in ~w(allow deny) do
    case Repo.get(PermissionRequest, id) do
      nil ->
        {:error, :not_found}

      %{tool_name: "tap_out", agent_id: agent_id} when is_binary(agent_id) ->
        resolve_tap_out(id, decision, answer)

      %{tool_name: "tap_out", session_id: session_id} when is_binary(session_id) ->
        resolve_tap_out(id, decision, answer)

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

  defp resolve_tap_out(id, decision, answer) do
    result =
      Repo.transaction(fn ->
        request = Repo.one(from p in PermissionRequest, where: p.id == ^id, lock: "FOR UPDATE")

        case request do
          %{status: "pending"} ->
            with {:ok, updated} <-
                   request
                   |> PermissionRequest.changeset(%{
                     status: decision_to_status(decision),
                     decision: decision
                   })
                   |> Repo.update(),
                 :ok <- apply_tap_out_decision(updated) do
              updated
            else
              {:error, reason} -> Repo.rollback(reason)
            end

          nil ->
            Repo.rollback(:not_found)

          %{status: status} ->
            Repo.rollback({:already_resolved, status})
        end
      end)

    with {:ok, updated} <- result do
      Phoenix.PubSub.broadcast(
        CodeMySpec.PubSub,
        "permission_request:#{id}",
        {:permission_decided, %{id: id, decision: decision}}
      )

      broadcast_notifications_changed(updated.user_id)
      :ok = clear_decline_on_deny(updated)

      if settle_tap_out_blocker(updated, answer) == 0,
        do: wake_if_still_in_the_loop(updated, answer)

      {:ok, updated}
    end
  end

  # A person saying "go and work" outranks the agent's own last refusal.
  # `Work` refuses to re-offer work an agent has already declined, which is
  # what stops it spinning — but this deny IS the answer to that refusal, so
  # without clearing the mark the wake would be suppressed and the deny would
  # do nothing at all. Before either wake below, which both run off-process.
  defp clear_decline_on_deny(%{decision: "deny", agent_id: agent_id}) when is_binary(agent_id) do
    case Repo.get(Agent, agent_id) do
      %Agent{} = agent ->
        announce(:decline_cleared, %{scope: owner_scope(agent), agent: agent})

      nil ->
        :ok
    end
  end

  defp clear_decline_on_deny(_request), do: :ok

  # The task a tap-out blocked goes through the same release as any blocker
  # (2200f9e4): denied or dismissed, it is released and its holder woken to
  # resume it, with the denial notice riding in the same turn; approved, the
  # task was already cancelled under the decision's lock, and this only makes
  # sure nothing is left blocked on it. Answers the count released — nothing
  # released means the plain denial below still has to reach the agent.
  defp settle_tap_out_blocker(%{task_id: nil}, _answer), do: 0

  defp settle_tap_out_blocker(%{decision: "allow"} = request, _answer) do
    {:ok, released} = TaskOwner.blocker_resolved(:tap_out, request.id, :approved)
    released
  end

  defp settle_tap_out_blocker(%{decision: "deny"} = request, answer) do
    {:ok, released} =
      TaskOwner.blocker_resolved(:tap_out, request.id, :denied,
        detail: tap_out_denied_notice(answer, request)
      )

    released
  end

  defp owner_scope(%Agent{} = agent) do
    %Scope{
      active_account_id: agent.account_id,
      active_project_id: agent.project_id,
      active_working_copy_id: agent.working_copy_id
    }
  end

  # Denying a tap-out puts the agent back in the loop, and nothing else was
  # going to notice. `Work.consider_*` is edge-triggered on a graph change, a
  # finished task, or continuous being switched on — a person answering a gate
  # is none of those, so an agent that had work the whole time goes on waiting
  # for a change that is not coming. Measured on the math project 2026-09-22:
  # coding sat eligible and idle for eight minutes after its tap-out was denied,
  # and the four roles behind it waited with it.
  #
  # Only on `deny`. `allow` takes the agent out of the loop, which is what it
  # asked for, and waking it would be answering the opposite question.
  #
  # Only when no task was released: a task-scoped denial wakes its holder
  # through `TaskOwner.blocker_resolved/4`, which carries this same notice.
  #
  # In a Task because this is reachable from inside the harness project channel,
  # and `Transport.Harness` dispatches by calling that channel's own process —
  # `:calling_self` kills it and cancels every turn on the copy.
  defp wake_if_still_in_the_loop(%{decision: "deny", agent_id: agent_id} = request, answer)
       when is_binary(agent_id) do
    case Repo.get(CodeMySpec.Agents.Agent, agent_id) do
      %{working_copy_id: copy_id} = agent when is_binary(copy_id) ->
        scope = %Scope{
          active_account_id: agent.account_id,
          active_project_id: agent.project_id,
          active_working_copy_id: copy_id
        }

        # Told before woken, and that ordering is the whole of it.
        #
        # The decision clears the gate on this side; the agent only knows what
        # is in its own transcript, and the last thing there is its own "I have
        # asked to leave and am waiting". Woken without being told, it reads
        # that, concludes it is still waiting, and stops — then the next wake
        # does it again. Measured on the math project 2026-09-22: the deny
        # landed, and coding answered "No change. Tap-out request af0dddfd still
        # pending. Stopping." every three seconds until it was taken out of the
        # loop by hand. The wake added in this same function is what turned a
        # silent stall into a spin, so this is its other half rather than a
        # separate fix.
        notice = tap_out_denied_notice(answer, request)

        # The notice goes in the turn rather than into the transcript ahead of
        # it. Recorded separately it is history the agent reads beside its own
        # last conclusion, and its own conclusion wins — measured twice, with
        # the resolved issue named by id nine seconds before the agent called
        # that same id unresolved. `offer_turn_with/3` makes the correction the
        # thing the agent is answering. It records the prompt itself, so the
        # notice still appears in the transcript exactly once.
        Task.Supervisor.start_child(CodeMySpec.TaskSupervisor, fn ->
          deliver_denial(scope, agent, copy_id, notice, {"tap_out", request.id})
        end)

        :ok

      _ ->
        :ok
    end
  end

  defp wake_if_still_in_the_loop(_request, _answer), do: :ok

  # In the turn when the agent can take one; recorded when it cannot.
  #
  # An agent mid-turn, reserved, or holding a task is not admissible, and it
  # still has to be told — so that case falls back to the old shape rather than
  # dropping the notice.
  defp deliver_denial(scope, agent, copy_id, notice, subject) do
    announce(:tap_out_denied, %{
      scope: scope,
      agent: agent,
      working_copy_id: copy_id,
      notice: notice,
      subject: subject
    })
  end

  # The reason carries, when the decider gave one.
  #
  # `answer_notification` has always accepted an `answer`, and for a permission
  # it went nowhere — the agent got this notice and nothing else. That is the
  # difference between "you are wrong that there is nothing to do" and telling
  # it *why*, and an agent with only the former re-reads its own transcript,
  # finds whatever it last concluded, and concludes it again.
  #
  # Measured on the math project 2026-09-22: QA's tap-out on a preview outage
  # was denied with an answer saying the outage was fixed, the URL was back to
  # 200, and which attempt to invalidate. None of it reached the agent, which
  # went on reporting the app unreachable — an outage that had ended four
  # minutes earlier — until it was stopped by hand.
  defp tap_out_denied_notice(answer, request) do
    base = """
    Your request to leave the loop was declined. You are still in it, and there
    is work for your role — that is why it was declined rather than granted.

    Do not wait on this any longer: it is answered. Carry on from
    `get_next_requirement`. If what you were blocked on has not changed, say so
    against the thing that is blocking you rather than asking to leave again.
    """

    base
    |> append_reason(answer)
    |> append_settled_blockers(request)
  end

  # Name the agent's own claim back to it when that claim has stopped being true.
  #
  # A reason is not enough on its own. Measured three times in one session: an
  # agent was denied with the fixing commit named in the message, and its next
  # turns still said "nothing has changed" — it re-reads its transcript, finds
  # its own last conclusion, and reaches it again, because a generic paragraph
  # does not contradict anything in particular.
  #
  # What broke the loop by hand, every time, was naming the specific statement:
  # "issue X, which your own request named, is now resolved". So the notice does
  # that itself when it can — the ids are in the reason the agent wrote, and
  # their status is a lookup.
  #
  # Silent when nothing the request named has moved, which is the honest answer:
  # in that case the agent's conclusion may well still hold, and the notice
  # should not imply otherwise.
  defp append_settled_blockers(notice, nil), do: notice

  defp append_settled_blockers(notice, request) do
    case settled_blockers(request) do
      [] ->
        notice

      settled ->
        notice <>
          """

          Specifically, these were named in your own request and have since been
          resolved:

          #{Enum.map_join(settled, "\n", &"  - #{&1.id} — #{&1.title}")}

          If your last conclusion rested on any of those, it no longer holds.
          Check before repeating it.
          """
    end
  end

  # Ids the agent wrote into its own reason, that are now resolved issues.
  #
  # By project_id rather than through `Issues.list_issues/1`, which reads
  # `scope.active_project.id` — the loaded association, not the id — so a scope
  # assembled from an agent row raises inside the repository and the rescue
  # below would quietly answer "nothing has changed", which is the exact
  # failure this function exists to prevent.
  defp settled_blockers(%{agent_id: agent_id, tool_input: input}) when is_binary(agent_id) do
    reason = MapAccess.get(input, :reason) || ""

    with true <- is_binary(reason) and reason != "",
         %{project_id: project_id} <- Repo.get(Agent, agent_id) do
      project_id
      |> Issues.resolved_in_project()
      |> Enum.filter(&String.contains?(reason, &1.id))
    else
      _ -> []
    end
  rescue
    _ -> []
  end

  defp settled_blockers(_request), do: []

  defp append_reason(base, nil), do: base
  defp append_reason(base, ""), do: base

  defp append_reason(base, answer) do
    base <>
      """

      Why it was declined:

      #{answer}

      This is new information from whoever answered you. Treat it as current and
      check it against what you last concluded before repeating that conclusion.
      """
  end

  defp apply_tap_out_decision(request) do
    case lock_tap_out_owner(request) do
      nil ->
        :ok

      owner ->
        scope = %Scope{active_account_id: owner.account_id, active_project_id: owner.project_id}

        case update_tap_out_owner(scope, owner, request) do
          {:ok, _} -> :ok
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp lock_tap_out_owner(%{agent_id: id}) when is_binary(id),
    do: Repo.one(from a in Agent, where: a.id == ^id, lock: "FOR UPDATE")

  defp lock_tap_out_owner(%{session_id: id}) when is_binary(id),
    do: Repo.one(from s in Session, where: s.id == ^id, lock: "FOR UPDATE")

  defp update_tap_out_owner(_scope, owner, %{task_id: nil, decision: "allow"}),
    do: owner |> Ecto.Changeset.change(continuous: false) |> Repo.update()

  defp update_tap_out_owner(scope, owner, %{decision: "allow"} = request),
    do: TaskOwner.cancel_blocked_task(scope, owner, request.task_id, request.id)

  # Released after the decision commits, by `settle_tap_out_blocker/2`.
  defp update_tap_out_owner(_scope, owner, _denied), do: {:ok, owner}

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
            release_dismissed_tap_out(updated)

            {:ok, updated}

          error ->
            error
        end

      %{status: status} ->
        {:error, {:already_resolved, status}}
    end
  end

  # Nobody deciding is not a verdict on the task, and nothing else would ever
  # clear its block — it is released to be resumed, never cancelled.
  defp release_dismissed_tap_out(%{tool_name: "tap_out", task_id: task_id, id: id})
       when is_binary(task_id) do
    {:ok, _released} = TaskOwner.blocker_resolved(:tap_out, id, :dismissed)
    :ok
  end

  defp release_dismissed_tap_out(_request), do: :ok

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
  defp deliver_decision_to_agent(%{tool_name: "tap_out"}), do: :ok

  defp deliver_decision_to_agent(%{agent_id: agent_id} = request) do
    announce(:decision_reached, %{agent_id: agent_id, text: decision_message(request)})
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

  @doc "The requests one Claude Code session raised, by its external id, oldest first."
  @spec list_permission_requests_for_session(String.t() | nil) :: [PermissionRequest.t()]
  def list_permission_requests_for_session(nil), do: []

  def list_permission_requests_for_session(session_external_id) do
    PermissionRequest
    |> join(:inner, [p], s in assoc(p, :session))
    |> where([_p, s], s.external_conversation_id == ^session_external_id)
    |> order_by([p], asc: p.inserted_at)
    |> Repo.all()
  end

  @doc """
  The agent's own pending tap-out on `task_id` (nil for the one naming no task),
  if it already has one. An agent holds at most one per task and one naming
  none.

  `request_agent_tap_out/2`'s caller must not create a second row while the
  first is undecided — an agent asks once and is told to stop, not to ask
  again, but `wake_project_roles/2`'s missing guard (fixed alongside this)
  handed it a menu with `tap_out` still offered on every unrelated project
  change while one was already pending, and each call created a fresh row.
  Measured live: 224 pending tap-out requests behind ten agents, one of them
  holding 129 — the tool creating a duplicate on every retry, not a human
  answering slowly.
  """
  @spec get_pending_tap_out_request(Ecto.UUID.t(), String.t() | nil) ::
          PermissionRequest.t() | nil
  def get_pending_tap_out_request(agent_id, task_id) when is_binary(agent_id),
    do: pending_tap_out(:agent_id, agent_id, task_id)

  # --- Question Requests (remote AskUserQuestion) ---

  @doc """
  Create a question request and notify the user via Web Push.

  Returns `{:ok, question_request}`. The caller subscribes to PubSub topic
  `"question_request:<id>"` to await the answer.
  """
  def create_question_request(user_id, %{} = attrs) do
    with {:ok, request} <- insert_question_request(user_id, attrs) do
      deliver_question(request)
      {:ok, request}
    end
  end

  @doc """
  Save a Claude Code session's question and its task blocker atomically, then
  deliver it — the session half of `create_agent_question_request/4`.

  `session_id` is the external conversation id the PreToolUse hook injects; a
  session that cannot be resolved from it (no id, a stale negotiation, no
  `register_session` yet) falls back to a plain, unblocked question rather
  than refusing the ask.
  """
  def create_session_question_request(scope, user_id, attrs, task_ref, session_id) do
    case session_id && Sessions.get_by_external_id(scope, session_id) do
      nil ->
        with {:ok, request} <- insert_question_request(user_id, attrs) do
          deliver_question(request)
          {:ok, request}
        end

      session ->
        result =
          Repo.transaction(fn ->
            with {:ok, task} <- question_task(session, task_ref),
                 attrs =
                   Map.merge(attrs, %{
                     "task_id" => task && task.id,
                     "story_id" => task && task.story_id
                   }),
                 {:ok, outcome} <- save_or_reuse_question_request(user_id, attrs),
                 :ok <- block_question_task(scope, session, task, request_from(outcome)) do
              outcome
            else
              {:error, reason} -> Repo.rollback(reason)
            end
          end)

        deliver_if_new(result)
    end
  end

  @doc "Save an agent's question and its task blocker atomically, then deliver it."
  def create_agent_question_request(scope, agent_id, attrs, task_ref \\ :active) do
    result =
      Repo.transaction(fn ->
        owner =
          Repo.one(
            from agent in CodeMySpec.Agents.Agent,
              where:
                agent.id == ^agent_id and agent.account_id == ^scope.active_account_id and
                  agent.project_id == ^scope.active_project_id,
              lock: "FOR UPDATE"
          )

        with {:ok, task} <- question_task(owner, task_ref),
             attrs =
               Map.merge(attrs, %{
                 "agent_id" => agent_id,
                 "task_id" => task && task.id,
                 "story_id" => task && task.story_id
               }),
             {:ok, outcome} <- save_or_reuse_question_request(scope.user.id, attrs),
             :ok <- block_question_task(scope, owner, task, request_from(outcome)) do
          outcome
        else
          {:error, reason} -> Repo.rollback(reason)
        end
      end)

    deliver_if_new(result)
  end

  # Issue fe683550: an agent whose wake decided to ask again before the
  # answer to its last identical question had arrived used to get a brand
  # new row, a brand new push, and a brand new wait — the exact repro was a
  # re-ask 58s after the first had already been answered. Reusing an open or
  # just-answered duplicate instead means the new blocker resolves against an
  # answer that may already be sitting there, rather than queueing behind one
  # nobody is going to send twice.
  @dedup_window_seconds 120

  defp save_or_reuse_question_request(user_id, attrs) do
    case duplicate_question_request(user_id, attrs) do
      nil ->
        with {:ok, request} <- insert_question_request(user_id, attrs), do: {:ok, {:new, request}}

      %QuestionRequest{} = request ->
        {:ok, {:duplicate, request}}
    end
  end

  defp request_from({_tag, request}), do: request

  defp deliver_if_new({:ok, {:new, request}}) do
    deliver_question(request)
    {:ok, request}
  end

  defp deliver_if_new({:ok, {:duplicate, request}}), do: {:ok, request}
  defp deliver_if_new(error), do: error

  defp duplicate_question_request(user_id, %{"questions" => [_ | _] = questions} = attrs) do
    cutoff = DateTime.add(DateTime.utc_now(), -@dedup_window_seconds, :second)

    QuestionRequest
    |> where([q], q.user_id == ^user_id and q.questions == ^questions)
    |> where([q], q.status == "pending" or (q.status == "answered" and q.updated_at > ^cutoff))
    |> scoped_to_same_story_or_task(attrs)
    |> order_by([q], desc: q.inserted_at)
    |> limit(1)
    |> Repo.one()
  end

  defp duplicate_question_request(_user_id, _attrs), do: nil

  defp scoped_to_same_story_or_task(query, %{"story_id" => story_id}) when not is_nil(story_id),
    do: where(query, [q], q.story_id == ^story_id)

  defp scoped_to_same_story_or_task(query, %{"task_id" => task_id}) when not is_nil(task_id),
    do: where(query, [q], q.task_id == ^task_id)

  defp scoped_to_same_story_or_task(query, _attrs), do: where(query, [q], false)

  defp question_task(nil, _task_ref), do: {:error, :owner_not_found}
  defp question_task(_owner, nil), do: {:ok, nil}
  defp question_task(owner, :active), do: {:ok, TaskOwner.active_task(owner)}

  # A task an agent may name to `tap_out` or `ask_user_question`.
  #
  # `:active` is the ordinary case. `:blocked` is accepted too, and that is the
  # whole of ce070442: it used to fall through to `{:error, :task_not_active}`,
  # which left a blocked task unreachable by `tap_out` — and `tap_out` is what
  # the loop's own refusal text tells an agent to reach for ("block it with
  # `ask_user_question` or `tap_out`, or `cancel_task`"). The report is that
  # sequence exactly: a `qa_complete` task blocked on a question, the question
  # answered, `start_task` refusing to resume it (`:requirement_not_eligible` on
  # the entity_id bug ab111a52), `tap_out` refusing it as inactive, and nothing
  # left but `cancel_task`, which discards the attempt rather than asking a
  # person.
  #
  # Re-blocking is not a contradiction. The agent is asking for a person to
  # decide, and the task is demonstrably not active *because* nobody has decided
  # the old blocker yet. `TaskOwner.block_task/6` names the new blocker, so
  # approving it frees exactly this task.
  defp question_task(owner, id) do
    case TaskOwner.find_task(owner, id) do
      %{status: status} = task when status in [:active, :blocked] -> {:ok, task}
      nil -> {:error, :task_not_found}
      _ -> {:error, :task_not_active}
    end
  end

  defp block_question_task(_scope, _owner, nil, _request), do: :ok

  defp block_question_task(scope, owner, task, request) do
    case TaskOwner.block_task(scope, owner, task.id, :question, request.id) do
      {:ok, _owner} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp insert_question_request(user_id, attrs) do
    attrs =
      attrs
      |> Map.merge(%{"user_id" => user_id, "status" => "pending"})
      |> put_anchor()

    %QuestionRequest{} |> QuestionRequest.changeset(attrs) |> Repo.insert()
  end

  defp deliver_question(request) do
    notify_user(request.user_id, %{
      type: "question_request",
      title: request.title || "A question for you",
      body: first_question_text(request.questions),
      url: question_url(request)
    })

    broadcast_notifications_changed(request.user_id)
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

    with :ok <- refuse_empty(answers) do
      settle_and_broadcast(id, answers, answered_by)
    end
  end

  @doc """
  The asker takes back its own pending question, with a reason (8c91d5bc).

  A question that went moot otherwise held its task until somebody answered
  something nobody needed answered. Withdrawn closes it everywhere a pending
  question is read, and releases the task it blocked through the one blocker
  path, `TaskOwner.blocker_resolved/3`. Who the asker is, is the caller's to
  check. Answers `{:ok, request, released_count}`.
  """
  @spec withdraw_question_request(String.t(), String.t()) ::
          {:ok, QuestionRequest.t(), non_neg_integer()} | {:error, term()}
  def withdraw_question_request(id, reason) when is_binary(id) and is_binary(reason) do
    case String.trim(reason) do
      "" -> {:error, :needs_a_reason}
      reason -> withdraw(id, reason)
    end
  end

  defp withdraw(id, reason) do
    result =
      Repo.transaction(fn ->
        from(q in QuestionRequest, where: q.id == ^id, lock: "FOR UPDATE")
        |> Repo.one()
        |> withdraw_locked(reason)
        |> case do
          {:ok, updated} -> updated
          {:error, refusal} -> Repo.rollback(refusal)
        end
      end)

    with {:ok, updated} <- result do
      broadcast_notifications_changed(updated.user_id)
      {:ok, released} = TaskOwner.blocker_resolved(:question, updated.id, :withdrawn)
      {:ok, updated, released}
    end
  end

  defp withdraw_locked(nil, _reason), do: {:error, :not_found}

  defp withdraw_locked(%{status: "pending"} = request, reason) do
    request
    |> QuestionRequest.changeset(%{status: "withdrawn", withdrawn_reason: reason})
    |> Repo.update()
  end

  defp withdraw_locked(%{status: status}, _reason), do: {:error, {:already_resolved, status}}

  # An answer that says nothing is not an answer, and as an override it is
  # destructive.
  #
  # Found by QA on story 1009, 2026-09-20: type a correction into the
  # "Other..." box without also clicking its radio, press Send, and the page
  # says "Answer sent" while `answers` is overwritten with `""`, `overruled`
  # becomes true, and a correct, record-backed main-agent answer stops being
  # the current value. Recoverable from `answer_history`, but every reader
  # treats the value as current — `check_answer` handed the asking agent "The
  # user replied, overruling the main agent's earlier answer:" followed by
  # nothing.
  #
  # Refused here rather than in the form, because the form is one of three
  # ways in — `QuestionLive`, the conversation page and `QuestionController`
  # all reach this, and a guard each caller has to remember is one the next
  # route will not.
  #
  # Only when *every* answer is blank. One unanswered question beside an
  # answered one is a partial reply, which is a person's to give.
  defp refuse_empty(answers) do
    if Enum.any?(answers, fn {_question, answer} -> answered?(answer) end) do
      :ok
    else
      {:error, :empty_answer}
    end
  end

  defp answered?(answer) when is_list(answer), do: Enum.any?(answer, &answered?/1)
  defp answered?(answer) when is_binary(answer), do: String.trim(answer) != ""
  defp answered?(nil), do: false
  defp answered?(_answer), do: true

  defp settle_and_broadcast(id, answers, answered_by) do
    result =
      Repo.transaction(fn ->
        request = Repo.one(from q in QuestionRequest, where: q.id == ^id, lock: "FOR UPDATE")

        case settle_answer(request, answers, answered_by) do
          {:ok, settled} -> settled
          {:error, reason} -> Repo.rollback(reason)
        end
      end)

    with {:ok, updated} <- result do
      Phoenix.PubSub.broadcast(
        CodeMySpec.PubSub,
        "question_request:#{updated.id}",
        {:question_answered, %{id: updated.id, answers: answers}}
      )

      broadcast_notifications_changed(updated.user_id)

      # Released and woken through the one path every blocker takes (2200f9e4).
      # Only a first answer, or a user's override of a still-waiting one, finds
      # anything: 3220's override of an answer whose task has already resumed
      # and re-blocked on a different question releases nothing and wakes
      # nobody, because nothing in front of the agent changed.
      {:ok, released} = TaskOwner.blocker_resolved(:question, updated.id, :answered)
      deliver_answer_content(updated, released > 0)
      {:ok, updated}
    end
  end

  # The answer as content, for an agent that is in the middle of a turn.
  #
  # Criterion 3577: a turn in flight is a conversation, and an answer that
  # lands during one belongs in it — queued behind the turn, never interrupting
  # it. 3219 is the other side and the reason for the guard: content pushed at
  # an idle machine *starts* a turn, and a durable question exists so that an
  # agent which stopped can collect its answer when it comes back rather than
  # be woken by it.
  #
  # Outside the transaction on purpose. `send_to_agent/2` dispatches to the
  # process holding the working copy, and doing that while still holding the
  # question's row lock is the shape of the failure John hit — a form
  # submission waiting out an agent's whole reply.
  #
  # A question asked without a task is the exception (9f03455b). It blocked
  # nothing, so answering it releases nothing, and the graph may have no work
  # to bring the agent back: metric_flow's coder asked f247789c, it was
  # answered at 16:18:35, and the coder sat idle until woken by hand. So an
  # idle continuous asker is offered one turn that opens with the answer —
  # John, 10-01: "if the agent asked the question and it's continuous it should
  # get the answer delivered". Whether it may be woken is `Agents.Wake`'s
  # (`:question_answered`): a non-continuous asker collects it when it comes
  # back (3219).
  #
  # Mid-turn the answer joins the turn whatever the question blocked. A
  # task-less answer mid-turn used to go nowhere: the turn ended, nothing
  # offered another, and the answer waited on `check_answer`.
  #
  # Idle with a task released: `TaskOwner.blocker_resolved/3` already woke it
  # with the task named.
  defp deliver_answer_content(%{agent_id: nil}, _released?), do: :ok

  # A task-scoped answer that released nothing (3220's override of a task that
  # already moved on) changes nothing in front of the agent, and says nothing.
  defp deliver_answer_content(%{task_id: task_id}, false) when not is_nil(task_id), do: :ok

  defp deliver_answer_content(request, released?) do
    case Repo.get(Agent, request.agent_id) do
      %Agent{turn_started_at: %DateTime{}} = agent ->
        announce(:answer_reached, %{
          agent: agent,
          scope: nil,
          text: answer_message(request, agent),
          question_id: request.id
        })

      %Agent{} = agent when not released? ->
        announce(:answer_reached, %{
          agent: agent,
          scope: owner_scope(agent),
          text: answer_message(request, agent),
          question_id: request.id
        })

      _released_or_gone ->
        :ok
    end
  end

  # What the agent reads mid-turn. Self-contained, because it is arriving in
  # the middle of something else: a reply without its question is a line of
  # dialogue with no idea what it answers.
  defp answer_message(%{questions: questions, answers: answers} = request, agent) do
    body =
      Enum.map_join(questions, "\n\n", fn question ->
        text = MapAccess.get(question, :question)
        "Q: #{text}\nA: #{said(answers, text)}"
      end)

    """
    The user answered your question.

    #{body}

    #{answer_closing(request, TaskOwner.active_task(agent))}
    """
  end

  defp answer_closing(%{task_id: nil}, _active),
    do: "It blocked no task. Carry on with whatever you asked it for."

  # The one message a mid-turn asker gets (`TaskOwner` sends none): never a
  # second active task (story 1080).
  defp answer_closing(%{task_id: task_id}, nil) do
    """
    This does not resume task #{task_id}, which it blocked. Pick that back up
    deliberately with `start_task` when you are ready for it.\
    """
  end

  defp answer_closing(%{task_id: task_id}, _active) do
    """
    Finish your active task first; task #{task_id}, which it blocked, is offered
    back to you once it is done.\
    """
  end

  defp said(answers, text) do
    case answers[text] || answers[to_string(text)] do
      nil -> "(no answer recorded)"
      list when is_list(list) -> Enum.join(list, ", ")
      value -> to_string(value)
    end
  end

  defp settle_answer(request, answers, answered_by) do
    case request do
      nil ->
        {:error, :not_found}

      %{status: "pending"} = request ->
        finish(request, answers, answered_by, false)

      %{status: "answered", answered_by: agent} = request
      when agent in ~w(main_agent product_agent) and answered_by == "user" ->
        finish(request, answers, answered_by, true)

      %{status: status} ->
        {:error, {:already_resolved, status}}
    end
  end

  # Only a committed answer revision reaches this path. Repeated submissions
  # are refused under the question row lock and cannot enqueue the same answer
  # again. A user override is a new revision and must carry its corrected text.
  # An answer is not a delivery.
  #
  # This used to `send_to_agent/2` the answer text the moment it was saved,
  # which made the machine busy and queued content for an agent that had asked
  # to be left alone. The plan retiring `wake` lists exactly this under what
  # goes: "task-control `send_to_agent` deliveries".
  #
  # Attribution lives on the saved question — `check_answer` reads who answered,
  # and reads it repeatedly — so nothing about knowing the answer depends on a
  # message arriving. Criterion 3219 states it as the claim: the originating
  # agent reads both answers twice while its conversation stays byte-identical
  # and its engine never takes a turn. 1047 and 1059 assert the same shape for
  # recovery checks and empty turn boundaries.
  #
  # What still happens on answer, once it commits: the question topic is
  # broadcast for anyone waiting, and the task it blocked is released and its
  # holder woken to resume it (`settle_and_broadcast/3`).

  defp finish(request, answers, answered_by, overruled) do
    request
    |> QuestionRequest.changeset(%{
      status: "answered",
      answers: answers,
      answered_by: answered_by,
      overruled: overruled,
      answer_history: history_with(request, overruled)
    })
    |> Repo.update()
  end

  # The answer this one replaces, kept where the page and the audit can find it.
  #
  # Only on an override: an ordinary first answer replaces nothing, and writing
  # an empty revision for it would make "has a history" stop meaning "was
  # overruled".
  defp history_with(request, false), do: request.answer_history || []

  defp history_with(request, true) do
    entry = %{
      "answers" => request.answers,
      "answered_by" => request.answered_by,
      "at" => DateTime.to_iso8601(DateTime.utc_now())
    }

    (request.answer_history || []) ++ [entry]
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
  same `agent_id` (`request_agent_tap_out/4`). A Claude Code session's tap-out
  is a row keyed by `session_id` instead, and `Hooks.Stop` reads only the
  `session.continuous` its approval clears.

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

  @doc """
  Get a question request by ID, or nil.

  Nil for an id that is not a uuid, too. Agents shorten ids in their own notes
  and call `check_answer` with `34a663ee`; `Repo.get/2` raised on the cast and
  the tool crashed instead of saying there is no such question (2999a0cb).
  """
  def get_question_request(id) do
    case Ecto.UUID.cast(id) do
      {:ok, uuid} -> Repo.get(QuestionRequest, uuid)
      :error -> nil
    end
  end

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

  # No option chosen, but something typed in "Other..." — which is a choice.
  #
  # There is no competing signal to weigh: a radio that *was* checked matches
  # the clause above and wins, so this only ever sees the case where the box
  # is the only thing the person touched. Reading it as blank turned a
  # correction into an erasure.
  defp resolve_answer(nil, other) when is_binary(other), do: other

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

  # What reaches an agent is Agents' to deliver (`Agents.Events`); Notifications
  # sits below Agents and announces instead of calling up (John, 2026-10-04).
  defp announce(event, meta) do
    :telemetry.execute([:code_my_spec, :notifications, event], %{}, meta)
  end
end
