defmodule CodeMySpec.GoogleAuthHelper do
  @moduledoc """
  Helper for getting Google OAuth tokens in tests.

  This module handles the OAuth flow automatically so tests can
  get fresh tokens without manual intervention.
  """

  @doc """
  Gets a valid Google OAuth access token for testing.

  Checks these sources in order:
  1. GOOGLE_ACCESS_TOKEN environment variable (if set)
  2. GOOGLE_REFRESH_TOKEN environment variable (exchanges for access token)
  3. Existing integration from database (if user is logged in)
  4. Raises with instructions if none available

  ## Examples

      iex> token = GoogleAuthHelper.get_token()
      "ya29.a0AfH6SMBw..."

  """

  alias GoogleApi.AnalyticsAdmin.V1beta.Connection

  def get_token do
    cond do
      access_token = System.get_env("GOOGLE_ACCESS_TOKEN") ->
        access_token

      refresh_token = System.get_env("GOOGLE_REFRESH_TOKEN") ->
        exchange_refresh_token(refresh_token)

      true ->
        raise """
        No Google OAuth token found. To record real API cassettes, set one of:

        1. GOOGLE_ACCESS_TOKEN (short-lived, ~1 hour):
           export GOOGLE_ACCESS_TOKEN="ya29.a0..."
           mix test --only skip

        2. GOOGLE_REFRESH_TOKEN (long-lived, can be reused):
           export GOOGLE_REFRESH_TOKEN="1//0..."
           mix test --only skip

        To get a refresh token:
        1. Go to https://developers.google.com/oauthplayground/
        2. Settings (⚙️) → Use your own OAuth credentials
        3. Enter GOOGLE_CLIENT_ID and GOOGLE_CLIENT_SECRET from .env
        4. Select: https://www.googleapis.com/auth/analytics.readonly
        5. Authorize and exchange code
        6. Copy the "Refresh token" (starts with "1//0")
        7. Save to .env: GOOGLE_REFRESH_TOKEN="1//0..."

        Refresh tokens last much longer than access tokens!
        """
    end
  end

  @doc """
  Exchanges a refresh token for a new access token.

  Uses the Google OAuth credentials from application config.
  """
  def exchange_refresh_token(refresh_token) do
    client_id = Application.fetch_env!(:code_my_spec, :google_client_id)
    client_secret = Application.fetch_env!(:code_my_spec, :google_client_secret)

    body =
      URI.encode_query(%{
        client_id: client_id,
        client_secret: client_secret,
        refresh_token: refresh_token,
        grant_type: "refresh_token"
      })

    case Req.post("https://oauth2.googleapis.com/token",
           body: body,
           headers: [{"content-type", "application/x-www-form-urlencoded"}]
         ) do
      {:ok, %{status: 200, body: %{"access_token" => access_token}}} ->
        access_token

      {:ok, %{status: status, body: body}} ->
        raise """
        Failed to exchange refresh token (HTTP #{status}):
        #{inspect(body)}

        Your refresh token may be expired or invalid.
        Get a new one from: https://developers.google.com/oauthplayground/
        """

      {:error, reason} ->
        raise """
        Failed to exchange refresh token:
        #{inspect(reason)}
        """
    end
  end

  @doc """
  Creates a Google Analytics Admin API connection using OAuth token.
  """
  def get_connection do
    token = get_token()
    Connection.new(token)
  end
end
