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
    reason = conn.assigns[:box_token_refusal] || :not_box_token
    Logger.warning("[DeviceToken] exchange refused: #{reason}")

    description =
      case reason do
        :missing_authorization ->
          "No Authorization header reached the server. Check the network secret for this host."

        :not_box_token ->
          "Authorization must be a dev box cbt_ token without a Bearer prefix in the network secret."

        :unknown_token ->
          "This dev box token is unknown to this server. Add a dev box on this server and use its token."

        :revoked_token ->
          "This dev box token was revoked. Add a new dev box and update its network secret."
      end

    refuse(conn, :unauthorized, to_string(reason), description)
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
