defmodule CodeMySpecWeb.PushSubscriptionController do
  @moduledoc """
  Controller for managing browser push notification subscriptions.

  These endpoints are called from the browser (browser session auth)
  to subscribe/unsubscribe from push notifications and retrieve the VAPID public key.
  """

  use CodeMySpecWeb, :controller

  alias CodeMySpec.Notifications

  @doc """
  POST /api/browser/push-subscriptions

  Create or update a push subscription for the current user.
  """
  def create(conn, %{"subscription" => sub_params}) do
    scope = conn.assigns.current_scope

    case Notifications.subscribe(scope.user_id, %{
           "endpoint" => sub_params["endpoint"],
           "p256dh_key" => get_in(sub_params, ["keys", "p256dh"]),
           "auth_key" => get_in(sub_params, ["keys", "auth"])
         }) do
      {:ok, _subscription} ->
        json(conn, %{status: "subscribed"})

      {:error, changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: "Failed to subscribe", details: inspect(changeset.errors)})
    end
  end

  def create(conn, _params) do
    conn
    |> put_status(:bad_request)
    |> json(%{error: "Missing subscription parameter"})
  end

  @doc """
  DELETE /api/browser/push-subscriptions

  Remove a push subscription by endpoint.
  """
  def delete(conn, %{"endpoint" => endpoint}) do
    case Notifications.unsubscribe(endpoint) do
      {:ok, _count} ->
        json(conn, %{status: "unsubscribed"})
    end
  end

  def delete(conn, _params) do
    conn
    |> put_status(:bad_request)
    |> json(%{error: "Missing endpoint parameter"})
  end

  @doc """
  GET /api/browser/push-subscriptions/vapid-key

  Return the VAPID public key for browser push subscription.
  """
  def vapid_key(conn, _params) do
    case Application.get_env(:web_push_elixir, :vapid_public_key) do
      nil ->
        conn
        |> put_status(:service_unavailable)
        |> json(%{error: "Push notifications not configured"})

      key ->
        json(conn, %{vapid_public_key: key})
    end
  end
end
