defmodule CodeMySpec.Notifications do
  @moduledoc """
  Push subscriptions and Web Push, and the requests that reach a person: question
  requests (`ask_question`) and permission requests (tool approvals and
  `tap_out`), with their inbox, holders, answers and the task blockers they
  release.

  See knowledge/agents/coordination, "Notifications".
  """

  use Boundary,
    top_level?: true,
    deps: [
      CodeMySpec.Accounts,
      CodeMySpec.Projects,
      CodeMySpec.Agents.Agent,
      CodeMySpec.Auth,
      CodeMySpec.Conversations,
      CodeMySpec.Issues,
      CodeMySpec.Repo,
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

  Fetches `limit` candidates from each schema and merges, which yields the
  true combined top `limit`.

  `:before` is `{inserted_at, seen_ids}`, not a bare timestamp: `inserted_at`
  has second precision, so requests in the same second tie, and `seen_ids`
  names the rows already shown at the boundary second.
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

  defp recipient_agents(user_id) do
    from a in Agent,
      join: p in assoc(a, :project),
      join: m in CodeMySpec.Accounts.Member,
      on: m.account_id == p.account_id,
      where: m.user_id == ^user_id and m.role in [:owner, :admin],
      select: a.id
  end

  defp visible_to(query, user_id) do
    where(
      query,
      [r],
      (is_nil(r.agent_id) and r.user_id == ^user_id) or
        r.agent_id in subquery(recipient_agents(user_id))
    )
  end

  @doc "Whether a user receives this request under the account membership rule."
  def recipient?(%{agent_id: nil, user_id: recipient_id}, user_id),
    do: recipient_id == user_id

  def recipient?(%{agent_id: agent_id}, user_id) do
    recipient_agents(user_id) |> where([a], a.id == ^agent_id) |> Repo.exists?()
  end

  defp recipient_ids(%{agent_id: nil, user_id: user_id}), do: [user_id]

  defp recipient_ids(%{agent_id: agent_id}) do
    Repo.all(
      from a in Agent,
        join: p in assoc(a, :project),
        join: m in CodeMySpec.Accounts.Member,
        on: m.account_id == p.account_id,
        where: a.id == ^agent_id and m.role in [:owner, :admin],
        select: m.user_id,
        distinct: true
    )
  end

  defp notify_recipients(request, payload) do
    Enum.each(recipient_ids(request), &notify_user(&1, payload))
  end

  defp broadcast_request_changed(request) do
    Enum.each(recipient_ids(request), &broadcast_notifications_changed/1)
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

  # A request whose named asker is off or retired is not waiting on anybody, so
  # it is hidden from the pending list (nothing is deleted). An agentless
  # request (a Claude Code session's) is kept: absent asker and departed asker
  # are different states. Pending lists only `holder == "user"` questions.
  # See knowledge/agents/coordination, "Notifications".
  defp pending_query(schema, user_id) do
    from(r in schema,
      where: r.status == "pending",
      where: is_nil(r.agent_id) or r.agent_id not in subquery(stopped_agent_ids()),
      order_by: [desc: r.inserted_at]
    )
    |> visible_to(user_id)
    |> held_by_user(schema)
  end

  # A question main or product still holds is not the user's to see yet. A
  # permission request has no `holder` column.
  defp held_by_user(query, QuestionRequest), do: where(query, [r], r.holder == "user")

  # A teammate's tap-out is main's until escalated. Main's own, and a Claude
  # Code session's, go to the user; every other permission kind is visible to
  # the user immediately.
  defp held_by_user(query, PermissionRequest) do
    where(
      query,
      [r],
      r.tool_name != "tap_out" or not is_nil(r.escalation_reason) or is_nil(r.agent_id) or
        r.agent_id in subquery(main_role_agent_ids())
    )
  end

  # Agents whose tap-outs are the person's: main's own, and a terminal
  # session's, which has nobody above it to route to.
  defp main_role_agent_ids do
    from(a in Agent,
      where: a.role == :main or a.engine in ^Agent.terminal_engines(),
      select: a.id
    )
  end

  # Off or retired: nobody means it to run. An agent on duty whose process is
  # down — restoring, or crashed — is still meant to answer.
  defp stopped_agent_ids do
    from(a in Agent, where: not is_nil(a.off_at) or not is_nil(a.retired_at), select: a.id)
  end

  # Not filtered by holder: the user's history carries what was fielded on
  # their behalf.
  defp resolved_query(schema, user_id) do
    from(r in schema,
      where: r.status != "pending",
      preload: [:answered_by_user],
      order_by: [desc: r.inserted_at],
      limit: @resolved_limit
    )
    |> visible_to(user_id)
  end

  defp resolved_page_query(schema, user_id, limit, before) do
    from(r in schema,
      where: r.status != "pending",
      preload: [:answered_by_user],
      order_by: [desc: r.inserted_at, desc: r.id],
      limit: ^limit
    )
    |> visible_to(user_id)
    |> before_cursor(before)
  end

  # Ties on `inserted_at` break on `id`, in the query and the in-memory merge
  # alike, so the two agree.
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

  # The badge counts what the list shows.
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
    notify_recipients(request, %{
      type: "permission_request",
      title: "#{request.tool_name} needs your approval",
      body: format_tool_summary(request.tool_name, request.tool_input),
      url: permission_url(request)
    })

    broadcast_request_changed(request)
  end

  @doc "Create one pending tap-out per agent/task intent, blocking linked work atomically."
  def request_agent_tap_out(scope, agent_id, task_id, reason \\ nil),
    do: request_tap_out(scope, Agent, agent_id, task_id, reason)

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

        open_or_reuse_tap_out(scope, owner, owner_key, owner_id, task_id, reason)
      end)

    with {:ok, {request, push?}} <- result do
      if push?, do: deliver_permission(request)

      {:ok, request}
    end
  end

  defp open_or_reuse_tap_out(scope, owner, owner_key, owner_id, task_id, reason) do
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
  end

  # A teammate's tap-out is the main agent's to decide, so the person is
  # pushed only for one that is theirs: main's own, or a terminal session's
  # (a person's process, with nobody above it to route to).
  defp user_decides?(%Agent{engine: engine}) when engine in [:claude_code, :codex], do: true
  defp user_decides?(%Agent{role: role}), do: role == :main

  defp tap_out_owner_key(Agent), do: :agent_id

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
  def resolve_permission_request(id, decision, answer \\ nil, opts \\ [])

  def resolve_permission_request(id, decision, answer, opts) when decision in ~w(allow deny) do
    answered_by_user_id = Keyword.get(opts, :answered_by_user_id)

    case Repo.get(PermissionRequest, id) do
      nil ->
        {:error, :not_found}

      %{tool_name: "tap_out", agent_id: agent_id} when is_binary(agent_id) ->
        resolve_tap_out(id, decision, answer, answered_by_user_id)

      %{status: "pending"} ->
        settle_permission(id, decision, answered_by_user_id)
        |> case do
          {:ok, updated} ->
            Phoenix.PubSub.broadcast(
              CodeMySpec.PubSub,
              "permission_request:#{id}",
              {:permission_decided, %{id: id, decision: decision}}
            )

            broadcast_request_changed(updated)
            deliver_decision_to_agent(updated)

            {:ok, updated}

          error ->
            error
        end

      %{status: status} ->
        {:error, {:already_resolved, status}}
    end
  end

  defp settle_permission(id, decision, answered_by_user_id) do
    Repo.transaction(fn ->
      case Repo.one(from p in PermissionRequest, where: p.id == ^id, lock: "FOR UPDATE") do
        nil ->
          Repo.rollback(:not_found)

        %{status: "pending"} = request ->
          request
          |> PermissionRequest.changeset(%{
            status: decision_to_status(decision),
            decision: decision,
            answered_by_user_id: answered_by_user_id
          })
          |> Repo.update()
          |> case do
            {:ok, updated} -> updated
            {:error, reason} -> Repo.rollback(reason)
          end

        %{status: status} ->
          Repo.rollback({:already_resolved, status})
      end
    end)
  end

  defp resolve_tap_out(id, decision, answer, answered_by_user_id) do
    result =
      Repo.transaction(fn ->
        request = Repo.one(from p in PermissionRequest, where: p.id == ^id, lock: "FOR UPDATE")

        decide_tap_out(request, decision, answered_by_user_id)
      end)

    with {:ok, updated} <- result do
      Phoenix.PubSub.broadcast(
        CodeMySpec.PubSub,
        "permission_request:#{id}",
        {:permission_decided, %{id: id, decision: decision}}
      )

      broadcast_request_changed(updated)
      :ok = clear_decline_on_deny(updated)

      if settle_tap_out_blocker(updated, answer) == 0,
        do: wake_if_still_in_the_loop(updated, answer)

      {:ok, updated}
    end
  end

  defp decide_tap_out(request, decision, answered_by_user_id) do
    case request do
      %{status: "pending"} ->
        with {:ok, updated} <-
               request
               |> PermissionRequest.changeset(%{
                 status: decision_to_status(decision),
                 decision: decision,
                 answered_by_user_id: answered_by_user_id
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
  end

  # A person saying "go and work" outranks the agent's own last refusal: without
  # clearing the decline the wake below would be damped. Before either wake.
  defp clear_decline_on_deny(%{decision: "deny", agent_id: agent_id}) when is_binary(agent_id) do
    case Repo.get(Agent, agent_id) do
      %Agent{} = agent ->
        announce(:decline_cleared, %{scope: owner_scope(agent), agent: agent})

      nil ->
        :ok
    end
  end

  defp clear_decline_on_deny(_request), do: :ok

  # The task a tap-out blocked goes through the same release as any blocker:
  # denied or dismissed, it is released and its holder woken to
  # resume it, with the denial notice riding in the same turn; approved, the
  # task was already cancelled under the decision's lock, and this only makes
  # sure nothing is left blocked on it. Answers the count released — nothing
  # released means the plain denial below still has to reach the agent.
  defp settle_tap_out_blocker(%{task_id: nil}, _answer), do: 0

  defp settle_tap_out_blocker(%{decision: "allow"} = request, _answer) do
    {:ok, released} = TaskOwner.blocker_resolved(:tap_out, request.id, :approved)
    released
  end

  # On 234810fe, main ruled the task-specific resume notice gets one wording
  # from one shared builder (TaskOwner.resolved_header/1 + resume_instruction/2,
  # matched in Work.offer_prompt_body/3) -- the "leave the loop" paragraph
  # tap_out_denied_notice/2 leads with does not fit a task-specific deny (it
  # describes the whole-agent continuous-stop case wake_if_still_in_the_loop/2
  # still uses it for) and no active 1080 criterion asks for that wording
  # here. But the actual information in that notice -- the decider's own
  # reason, and any blocker it named that has since resolved -- is real and
  # stays: tap_out_task_denied_detail/2 carries only that, not the
  # mismatched lead paragraph.
  defp settle_tap_out_blocker(%{decision: "deny"} = request, answer) do
    {:ok, released} =
      TaskOwner.blocker_resolved(:tap_out, request.id, :denied,
        detail: tap_out_task_denied_detail(answer, request)
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

  # A denied tap-out is a wake edge of its own: offering is edge-triggered and
  # a person answering a gate is no other edge. Only on `deny`, and only when no
  # task was released (that path wakes its holder with the same notice). In a
  # Task: reachable from inside the harness channel, which dispatch calls into.
  defp wake_if_still_in_the_loop(%{decision: "deny", agent_id: agent_id} = request, answer)
       when is_binary(agent_id) do
    case Repo.get(CodeMySpec.Agents.Agent, agent_id) do
      %{working_copy_id: copy_id} = agent when is_binary(copy_id) ->
        scope = %Scope{
          active_account_id: agent.account_id,
          active_project_id: agent.project_id,
          active_working_copy_id: copy_id
        }

        # Told in the same turn it is woken: woken without being told, it reads
        # its own "waiting on my tap-out" and stops again. The notice is the turn
        # prompt (`Work.offer_turn_with/5`), not a prior transcript line, which
        # it would read past.
        notice = tap_out_denied_notice(answer, request)

        Task.Supervisor.start_child(CodeMySpec.TaskSupervisor, fn ->
          deliver_denial(scope, agent, copy_id, notice, {"tap_out", request.id})
        end)

        :ok

      _ ->
        :ok
    end
  end

  defp wake_if_still_in_the_loop(_request, _answer), do: :ok

  # Announced for `Agents` to deliver: in a turn when the agent can take one,
  # recorded when it cannot.
  defp deliver_denial(scope, agent, copy_id, notice, subject) do
    announce(:tap_out_denied, %{
      scope: scope,
      agent: agent,
      working_copy_id: copy_id,
      notice: notice,
      subject: subject
    })
  end

  # The decider's reason carries: without the why, an agent re-reads its own
  # transcript and reaches its last conclusion again.
  # The reason and settled-blockers reconciliation alone, with no lead
  # paragraph -- for a task-specific deny, whose own resume text (built by
  # Work.offer_prompt_body/3, matching TaskOwner.resolved_header/1) already
  # says what happened.
  defp tap_out_task_denied_detail(answer, request) do
    ""
    |> append_reason(answer)
    |> append_settled_blockers(request)
    |> String.trim_leading()
  end

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

  # Names the agent's own claim back to it when it stopped being true: issues
  # its request named that are now resolved. A generic reason contradicts
  # nothing in particular. Silent when nothing named has moved.
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
  # By project_id: `Issues.list_issues/1` reads the loaded `active_project`,
  # which a scope built from an agent row lacks.
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

  defp update_tap_out_owner(_scope, owner, %{task_id: nil, decision: "allow"}),
    do: owner |> Ecto.Changeset.change(continuous: false) |> Repo.update()

  defp update_tap_out_owner(scope, owner, %{decision: "allow"} = request),
    do: TaskOwner.cancel_blocked_task(scope, owner, request.task_id, request.id)

  # Released after the decision commits, by `settle_tap_out_blocker/2`.
  defp update_tap_out_owner(_scope, owner, _denied), do: {:ok, owner}

  @doc """
  Clear a pending permission request without a decision.

  A human's choice that the request no longer matters, distinct from
  allow/deny (`resolve_permission_request/3`). Marked `"expired"`, not
  `"denied"`, so the list tells "nobody decided" from "somebody said no"; a
  live agent still hears the decision. Questions have no dismiss: a question
  is answered or withdrawn.
  """
  @spec dismiss_permission_request(Ecto.UUID.t()) ::
          {:ok, PermissionRequest.t()} | {:error, term()}
  def dismiss_permission_request(id) do
    case Repo.get(PermissionRequest, id) do
      nil -> {:error, :not_found}
      %{status: "pending"} = request -> expire_permission_request(request)
      %{status: status} -> {:error, {:already_resolved, status}}
    end
  end

  defp expire_permission_request(%{id: id} = request) do
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

        broadcast_request_changed(updated)
        deliver_decision_to_agent(updated)
        release_dismissed_tap_out(updated)

        {:ok, updated}

      error ->
        error
    end
  end

  @doc """
  Retire a pending, task-less tap-out once its agent has, in fact, resumed.

  `Agents.Waiting` stops treating a task-less tap-out as holding the whole
  agent the moment it gains an active task — "An agent still holding a task
  is not idle on it." Nothing used to tell the permission row that: it sat
  `"pending"`, still claiming "it cannot be woken" (`OpenQuestion`), while
  the agent it named was demonstrably taking turns. d2044280 caught two
  agents read as frozen pending a decision that had, in effect, already
  stopped applying.

  Called wherever a task is handed back to an agent — a fresh claim or a
  resume — so the retirement follows the same event that already freed it
  to work, rather than a second decision nobody is positioned to make. A
  tap-out naming a task is untouched: it holds only that task (story 1080),
  so working on a different one is not the contradiction this fixes.
  """
  @spec retire_resumed_tap_out(Agent.t() | term()) :: :ok
  def retire_resumed_tap_out(%Agent{id: agent_id}) when is_binary(agent_id) do
    PermissionRequest
    |> where(
      [p],
      p.agent_id == ^agent_id and p.status == "pending" and p.tool_name == "tap_out" and
        is_nil(p.task_id)
    )
    |> Repo.one()
    |> case do
      nil -> :ok
      request -> with {:ok, _} <- expire_permission_request(request), do: :ok
    end
  end

  def retire_resumed_tap_out(_owner), do: :ok

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

  # Tell an agent we run what was decided (a Claude Code request is answered on
  # its waiting SSE connection). Tap-outs are settled on their own path.
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

  The permission-request counterpart of `list_question_requests_for_agent/1`,
  for an agent's transcript.
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
  The agent's own pending tap-out on `task_id` (nil for the one naming no task),
  if it already has one. An agent holds at most one per task and one naming
  none.

  A caller must not create a second row while the first is undecided;
  `request_agent_tap_out/4` reuses the pending one.
  """
  @spec get_pending_tap_out_request(Ecto.UUID.t(), String.t() | nil) ::
          PermissionRequest.t() | nil
  def get_pending_tap_out_request(agent_id, task_id) when is_binary(agent_id),
    do: pending_tap_out(:agent_id, agent_id, task_id)

  # --- Question Requests (remote AskQuestion) ---

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

  # An identical question, pending or answered within the window, on the same
  # story or task, is reused rather than re-asked: the new blocker resolves
  # against an answer that may already be there.
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

  # Reusing an answered question creates a new task blocker, but no new
  # answer event will arrive to release it. Release after the transaction
  # commits so the normal wake path sees the persisted blocker.
  defp deliver_if_new({:ok, {:duplicate, %{status: "answered"} = request}}) do
    with {:ok, _released} <-
           TaskOwner.blocker_resolved(:question, request.id, :answered, detail: answered(request)) do
      {:ok, request}
    end
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

  # A task an agent may name to `tap_out` or `ask_question`: active or
  # blocked. Re-blocking a blocked task names the new blocker, so deciding it
  # frees exactly this task; otherwise only `cancel_task` could reach it.
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
    notify_recipients(request, %{
      type: "question_request",
      title: request.title || "A question for you",
      body: first_question_text(request.questions),
      url: question_url(request)
    })

    broadcast_request_changed(request)
  end

  @doc """
  Record answers to a question request and broadcast them so the waiting hook
  receives them. `answers` maps each question's text to the chosen label(s).

  `answered_by` defaults to `"user"`; `Agents.Main` overrides it when main or
  product answers.

  ## Overruling, in one direction only

  A request main or product already answered can be answered again by the
  user: the new answer replaces the old, `overruled` is set, and the old one
  goes to `answer_history`. Every other repeat is refused — a user's answer is
  the one that stands.
  """
  def answer_question_request(id, %{} = answers, opts \\ []) do
    answered_by = Keyword.get(opts, :answered_by, "user")

    with :ok <- refuse_empty(answers) do
      settle_and_broadcast(id, answers, answered_by, Keyword.get(opts, :answered_by_user_id))
    end
  end

  @doc """
  The asker takes back its own pending question, with a reason.

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
      broadcast_request_changed(updated)
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

  # An answer that says nothing is refused here, for every route in; as an
  # override it would erase a good answer. Only when every answer is blank: a
  # partial reply is a person's to give.
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

  defp settle_and_broadcast(id, answers, answered_by, answered_by_user_id) do
    result =
      Repo.transaction(fn ->
        request = Repo.one(from q in QuestionRequest, where: q.id == ^id, lock: "FOR UPDATE")

        case settle_answer(request, answers, answered_by, answered_by_user_id) do
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

      broadcast_request_changed(updated)

      # Released and woken through the one path every blocker takes. An
      # override of an answer whose task already moved on releases nothing.
      # The answer rides in the resume notice of a task it releases (2175).
      {:ok, released} =
        TaskOwner.blocker_resolved(:question, updated.id, :answered, detail: answered(updated))

      deliver_answer_content(updated, released > 0)
      tell_escalator(updated)
      {:ok, updated}
    end
  end

  # The answer as content. Mid-turn it joins the turn (queued, never
  # interrupting). Idle with nothing released (a task-less question), the asker
  # is offered a turn opening with the answer, if `Agents.Wake` allows
  # (`:question_answered`); otherwise it collects it with `check_answer`. Idle
  # with a task released: `TaskOwner.blocker_resolved/3` already woke it.
  # Outside the transaction: delivery must not hold the question's row lock.
  defp deliver_answer_content(%{agent_id: nil}, _released?), do: :ok

  # A task-scoped answer that released nothing (an override of a task that
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

  # The agent that escalated the question hears the answer too, so it can act
  # on the user's decision.
  defp tell_escalator(%{answered_by: "user", escalated_by: by, agent_id: asker_id} = request)
       when is_binary(by) and is_binary(asker_id) do
    case Repo.get(Agent, asker_id) do
      %Agent{} = asker ->
        announce(:escalated_answer_reached, %{
          scope: owner_scope(asker),
          asker: asker,
          escalated_by: by,
          text: escalator_message(request, asker)
        })

      nil ->
        :ok
    end
  end

  defp tell_escalator(_request), do: :ok

  defp escalator_message(%{questions: questions, answers: answers} = request, asker) do
    body =
      Enum.map_join(questions, "\n\n", fn question ->
        text = MapAccess.get(question, :question)
        "Q: #{text}\nA: #{said(answers, text)}"
      end)

    """
    The user answered question #{request.id}, which you escalated for the \
    #{asker.role} agent #{asker.id}. The asker has the answer too.

    #{body}
    """
  end

  # What the agent reads mid-turn. Self-contained, because it is arriving in
  # the middle of something else: a reply without its question is a line of
  # dialogue with no idea what it answers.
  defp answer_message(request, agent) do
    """
    #{answer_author(request)} answered your question.

    #{answer_body(request)}

    #{answer_closing(request, TaskOwner.active_task(agent))}
    """
  end

  defp answer_body(%{questions: questions, answers: answers}) do
    Enum.map_join(questions, "\n\n", fn question ->
      text = MapAccess.get(question, :question)
      "Q: #{text}\nA: #{said(answers, text)}"
    end)
  end

  defp answer_closing(%{task_id: nil}, _active),
    do: "It blocked no task. Carry on with whatever you asked it for."

  # The one message a mid-turn asker gets (`TaskOwner` sends none): never a
  # second active task.
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

  defp settle_answer(request, answers, answered_by, answered_by_user_id) do
    case request do
      nil ->
        {:error, :not_found}

      %{status: "pending"} = request ->
        finish(request, answers, answered_by, false, answered_by_user_id)

      %{status: "answered", answered_by: agent} = request
      when agent in ~w(main_agent product_agent) and answered_by == "user" ->
        finish(request, answers, answered_by, true, answered_by_user_id)

      %{status: status} ->
        {:error, {:already_resolved, status}}
    end
  end

  # Saving an answer is not delivering it: `check_answer` reads the saved
  # question. Repeats are refused under the row lock. Broadcast and release
  # happen after commit, in `settle_and_broadcast/4`.

  defp finish(request, answers, answered_by, overruled, answered_by_user_id) do
    request
    |> QuestionRequest.changeset(%{
      status: "answered",
      answers: answers,
      answered_by: answered_by,
      answered_by_user_id: answered_by_user_id,
      overruled: overruled,
      answer_history: history_with(request, overruled)
    })
    |> Repo.update()
  end

  # The answer this one replaces, only on an override, so "has a history"
  # means "was overruled".
  defp history_with(request, false), do: request.answer_history || []

  defp history_with(request, true) do
    entry = %{
      "answers" => request.answers,
      "answered_by" => request.answered_by,
      "at" => DateTime.to_iso8601(DateTime.utc_now())
    }

    (request.answer_history || []) ++ [entry]
  end

  # Where tapping the notification lands: the asker's conversation, anchored to
  # the question; the standalone page for an asker without one (Claude Code).
  defp question_url(%{agent_id: agent_id, id: id}) when is_binary(agent_id) do
    case conversation_for_agent(agent_id) do
      %{id: conversation_id, project_id: project_id} ->
        "/app/projects/#{project_id}/agent-conversation?conversation=#{conversation_id}#question-#{id}"

      _ ->
        "/app/questions/#{id}"
    end
  end

  defp question_url(%{id: id}), do: "/app/questions/#{id}"

  # Same rule as `question_url/1`, anchored to the request itself (a permission
  # request records no message).
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

  # Where in the transcript this question was asked: the newest message in the
  # asking agent's conversation (at worst the turn before). An explicit value
  # wins; a Claude Code session has none.
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
  Whether this agent has a pending question or permission request (a tap-out
  included). Two tables, one question; indexed on `(agent_id, status)`.
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
  What the user answered to this question, as its resume notice carries it,
  or nil when it is not answered. An answer offer's later rung repeats it.
  """
  @spec answer_detail(String.t()) :: String.t() | nil
  def answer_detail(question_id) do
    case get_question_request(question_id) do
      %QuestionRequest{answers: answers} = request when not is_nil(answers) -> answered(request)
      _unanswered -> nil
    end
  end

  defp answered(request),
    do: answer_author(request) <> " answered your question.\n\n" <> answer_body(request)

  defp answer_author(%{answered_by: "main_agent"}), do: "The main agent"
  defp answer_author(%{answered_by: "product_agent"}), do: "The product agent"
  defp answer_author(_request), do: "The user"

  @doc """
  Get a question request by ID, or nil.

  Nil for an id that is not a uuid, too: agents pass shortened ids.
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

  A question belongs to a session (a Claude Code process with an external id)
  or an agent (a row we own), never both; an agent's questions carry no
  `session_external_id`.
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

  The project screen's view, so a question from a worktree nobody is watching
  is still seen. Pending only.
  """
  @spec list_pending_question_requests_for_user(integer()) :: [QuestionRequest.t()]
  def list_pending_question_requests_for_user(user_id) when is_integer(user_id) do
    QuestionRequest
    |> visible_to(user_id)
    |> where([q], q.status == "pending")
    |> order_by([q], asc: q.inserted_at)
    |> Repo.all()
  end

  @doc """
  Turn a submitted form into `%{question text => answer}`.

  Here rather than in a LiveView: two hosts submit this shape, and the
  "__other__" convention belongs to the form component.
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
  rescue
    # WebPushElixir.send_notification/2 only returns {:ok, _} / {:error, _} for
    # an HTTP response; a transport failure (timeout, connection refused) comes
    # back from Req.run/1 as {request, %Req.TransportError{}}, which its own
    # case has no clause for, so it raises instead. The question this push is
    # announcing is already durable server-side by the time we get here, so a
    # raise here must not undo it.
    error ->
      Logger.warning(
        "[Notifications] Failed to send push to #{subscription.endpoint}: " <>
          Exception.format(:error, error, __STACKTRACE__)
      )
  end

  # What reaches an agent is Agents' to deliver (`Agents.Events`); Notifications
  # sits below Agents and announces instead of calling up.
  defp announce(event, meta) do
    :telemetry.execute([:code_my_spec, :notifications, event], %{}, meta)
  end
end
