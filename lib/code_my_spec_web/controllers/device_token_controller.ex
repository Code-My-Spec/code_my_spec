defmodule CodeMySpecWeb.DeviceTokenController do
  @moduledoc """
  A dev box trades its own token for a short-lived access token (story 1131),
  the way a sprite trades its deploy key (`SpriteTokenController`).

  The box is whichever one the token was minted for: `Plugs.DeployKeyOrOAuth`
  resolves the bearer credential, and nothing in the request body can name a
  different box. In Claude Code cloud the credential is not the harness's to
  send; Anthropic's proxy adds the header in transit.
  """

  use CodeMySpecWeb, :controller

  alias CodeMySpec.Accounts
  alias CodeMySpec.Oauth

  require Logger

  @default_ttl 3600

  def create(%Plug.Conn{assigns: %{box_device: box}} = conn, _params) do
    with %{} = owner <- Accounts.get_account_owner(box.account_id),
         {:ok, token} <- Oauth.issue_box_token(box, owner, ttl()) do
      json(conn, %{
        access_token: token.token,
        token_type: "Bearer",
        expires_in: token.expires_in,
        device_id: box.id
      })
    else
      _ ->
        Logger.error("[DeviceToken] could not issue a token for box #{box.id}")

        refuse(
          conn,
          :internal_server_error,
          "token_creation_failed",
          "No access token could be issued."
        )
    end
  end

  def create(conn, _params) do
    refuse(
      conn,
      :unauthorized,
      "invalid_token",
      "Sign in with a dev box token; this credential is not one."
    )
  end

  defp refuse(conn, status, error, description) do
    conn |> put_status(status) |> json(%{error: error, error_description: description})
  end

  defp ttl do
    :code_my_spec
    |> Application.get_env(CodeMySpec.Devices, [])
    |> Keyword.get(:access_token_ttl, @default_ttl)
  end
end
