defmodule CodeMySpecWeb.TokenController do
  @moduledoc """
  Exchanges a deployed app's refresh secret for a short-lived access token.

  The one endpoint the refresh secret opens. Everything else the app calls
  takes the exchanged token instead — see `CodeMySpecWeb.Plugs.AppToken`.
  """

  use CodeMySpecWeb, :controller

  alias CodeMySpec.AppTokens

  def create(conn, %{"refresh_secret" => refresh_secret}) do
    case AppTokens.exchange(refresh_secret) do
      {:ok, token, expires_in} ->
        json(conn, %{"access_token" => token, "expires_in" => expires_in, "token_type" => "Bearer"})

      {:error, :invalid} ->
        # Deliberately one refusal. Telling an unauthenticated caller *why*
        # their secret failed tells an attacker the same thing.
        conn
        |> put_status(401)
        |> json(%{"error" => "unauthorized", "reason" => "invalid"})
    end
  end

  def create(conn, _params) do
    conn
    |> put_status(400)
    |> json(%{"error" => "invalid_request", "reason" => "refresh_secret is required"})
  end
end
