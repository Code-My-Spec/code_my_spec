defmodule CodeMySpec.LocalServer.NotificationClient do
  @moduledoc """
  Sends push notifications by threading them through the production server.

  Uses the same OAuth token + server URL pattern as `BootstrapController.list_projects/1`
  to make authenticated API calls to the production server's notification endpoint.
  The OAuth token identifies the user; notifications go to all that user's subscribed browsers.
  """

  require Logger

  alias CodeMySpec.Auth.OAuthClient

  @doc """
  Send a notification via the production server.

  Makes an authenticated POST to `/api/notifications/push` on the production server.
  The OAuth token identifies the user — production looks up their subscriptions.
  Silently succeeds if not authenticated (user hasn't connected to production).
  """
  def notify(%{} = payload) do
    case OAuthClient.get_token() do
      {:ok, token} ->
        server_url = OAuthClient.get_server_url()
        url = "#{server_url}/api/notifications/push"

        headers = [{"authorization", "Bearer #{token}"}]

        case Req.post(url, headers: headers, json: payload) do
          {:ok, %{status: 200}} ->
            Logger.debug("[NotificationClient] Notification sent")
            :ok

          {:ok, %{status: 401}} ->
            Logger.warning("[NotificationClient] Authentication expired, skipping notification")
            :ok

          {:ok, %{status: status, body: body}} ->
            Logger.warning(
              "[NotificationClient] Server returned #{status}: #{inspect(body)}"
            )

            :ok

          {:error, reason} ->
            Logger.warning(
              "[NotificationClient] Failed to reach server: #{inspect(reason)}"
            )

            :ok
        end

      {:error, _} ->
        Logger.debug("[NotificationClient] Not authenticated, skipping notification")
        :ok
    end
  end
end
