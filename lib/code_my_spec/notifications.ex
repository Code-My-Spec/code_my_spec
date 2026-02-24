defmodule CodeMySpec.Notifications do
  @moduledoc """
  Context for managing push notification subscriptions and sending Web Push notifications.
  """

  require Logger

  import Ecto.Query

  alias CodeMySpec.Notifications.PushSubscription
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
