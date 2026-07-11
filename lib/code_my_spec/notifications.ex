defmodule CodeMySpec.Notifications do
  @moduledoc """
  Context for managing push notification subscriptions and sending Web Push notifications.
  """

  require Logger

  import Ecto.Query

  alias CodeMySpec.Notifications.PermissionRequest
  alias CodeMySpec.Notifications.PushSubscription
  alias CodeMySpec.Notifications.QuestionRequest
  alias CodeMySpec.Repo

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
    (pending_query(QuestionRequest, user_id) |> Repo.all()) ++
      (pending_query(PermissionRequest, user_id) |> Repo.all())
    |> Enum.sort_by(& &1.inserted_at, {:desc, DateTime})
  end

  defp resolved_notifications(user_id) do
    (resolved_query(QuestionRequest, user_id) |> Repo.all()) ++
      (resolved_query(PermissionRequest, user_id) |> Repo.all())
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
          url: "/app/permissions/#{request.id}"
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
        |> PermissionRequest.changeset(%{status: decision_to_status(decision), decision: decision})
        |> Repo.update()
        |> case do
          {:ok, updated} ->
            Phoenix.PubSub.broadcast(
              CodeMySpec.PubSub,
              "permission_request:#{id}",
              {:permission_decided, %{id: id, decision: decision}}
            )

            broadcast_notifications_changed(updated.user_id)

            {:ok, updated}

          error ->
            error
        end

      %{status: status} ->
        {:error, {:already_resolved, status}}
    end
  end

  @doc """
  Get a permission request by ID.
  """
  def get_permission_request(id), do: Repo.get(PermissionRequest, id)

  # --- Question Requests (remote AskUserQuestion) ---

  @doc """
  Create a question request and notify the user via Web Push.

  Returns `{:ok, question_request}`. The caller subscribes to PubSub topic
  `"question_request:<id>"` to await the answer.
  """
  def create_question_request(user_id, %{} = attrs) do
    attrs = Map.merge(attrs, %{"user_id" => user_id, "status" => "pending"})

    with {:ok, request} <-
           %QuestionRequest{} |> QuestionRequest.changeset(attrs) |> Repo.insert() do
      notify_user(user_id, %{
        type: "question_request",
        title: request.title || "Claude Code has a question",
        body: first_question_text(request.questions),
        url: "/app/questions/#{request.id}"
      })

      broadcast_notifications_changed(user_id)

      {:ok, request}
    end
  end

  @doc """
  Record answers to a question request and broadcast them so the waiting hook
  receives them. `answers` maps each question's text to the chosen label(s).
  """
  def answer_question_request(id, %{} = answers) do
    case Repo.get(QuestionRequest, id) do
      nil ->
        {:error, :not_found}

      %{status: "pending"} = request ->
        request
        |> QuestionRequest.changeset(%{status: "answered", answers: answers})
        |> Repo.update()
        |> case do
          {:ok, updated} ->
            Phoenix.PubSub.broadcast(
              CodeMySpec.PubSub,
              "question_request:#{id}",
              {:question_answered, %{id: id, answers: answers}}
            )

            broadcast_notifications_changed(updated.user_id)

            {:ok, updated}

          error ->
            error
        end

      %{status: status} ->
        {:error, {:already_resolved, status}}
    end
  end

  @doc "Get a question request by ID."
  def get_question_request(id), do: Repo.get(QuestionRequest, id)

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
        Logger.info(
          "[Notifications] Subscription expired, removing: #{subscription.endpoint}"
        )

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
