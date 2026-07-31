defmodule CodeMySpecWeb.SpriteTokenController do
  @moduledoc """
  Trades a project's deploy key for a real OAuth access token.

  ## Why an exchange rather than widening the deploy key

  A sprite has no user and no browser, so it cannot run an authorization-code
  flow. It holds one credential: its project's deploy key. But the deploy key is
  deliberately narrow — `Plugs.DeployKeyOrOAuth` says so in as many words, and
  mounts on the question routes only, because a key that can interrupt its owner
  should not thereby inherit everything that owner can do.

  Accepting the deploy key across the harness tool surface would have widened it
  to exactly that. Exchanging it for a token keeps the boundary where it is and
  moves the sprite onto the same credential every other client uses, which means
  `require_oauth_token` needs no special case and neither does anything
  downstream of it.

  What the exchange buys beyond tidiness:

    * **Expiry.** A deploy key is valid until someone rotates it. A token is
      valid for an hour, so a sprite's credential stops being useful shortly
      after the sprite does.
    * **Revocation that fits the unit of work.** Revoking a deploy key stops
      every sprite on that project and the laptop besides. Revoking one token
      stops one sprite.
    * **A resource owner.** `require_oauth_token` resolves the user from
      `resource_owner_id`, and a `client_credentials` grant has none — such a
      token would reach `Users.get_user!(nil)` and raise. Minting against the
      account owner is what makes the token work with the pipeline as it stands.

  The token is the account owner's, scoped to the deploy key's own project, on
  the same reasoning `DeployKeyOrOAuth` already applies: on their project it is
  their decision to make.
  """

  use CodeMySpecWeb, :controller

  alias ExOauth2Provider.AccessTokens

  require Logger

  # Sized to outlast a run, because **nothing refreshes this**.
  #
  # The token is handed to the agent's MCP client, which knows nothing about
  # deploy keys and will not re-exchange. So the lifetime is not a security dial
  # to be turned down freely: set it below the length of a run and tool calls
  # start 401ing partway through, which is the "a long session silently loses its
  # harness tools" failure with a new cause. The last unattended drill ran 2h11m.
  #
  # Twelve hours covers a long drill with room, and is still bounded and
  # individually revocable, which a deploy key is not. Shortening this is only
  # safe once something on the sprite refreshes it.
  @expires_in 12 * 60 * 60

  @doc """
  Exchange the deploy key in the `Authorization` header for an access token.

  Reached through `Plugs.DeployKeyOrOAuth`, which has already validated the
  credential and assigned the scope. An OAuth caller gets a token for
  themselves, which is harmless and keeps the route uniform.
  """
  def create(conn, _params) do
    scope = conn.assigns.current_scope

    case AccessTokens.create_token(
           scope.user,
           # No `scopes:`. Nothing configures `default_scopes` for this provider,
           # so the permitted list is empty and *any* explicit scope is rejected
           # as "not in permitted scopes list: []". Authorization here is carried
           # by the scope the pipeline builds, not by an OAuth scope string.
           %{expires_in: @expires_in},
           otp_app: :code_my_spec
         ) do
      {:ok, token} ->
        Logger.info(
          "[SpriteToken] issued a #{@expires_in}s token for project #{scope.active_project_id}"
        )

        json(conn, %{
          # `:token`, not `:access_token` — that is the field name on
          # `CodeMySpec.Oauth.AccessToken`.
          access_token: token.token,
          token_type: "Bearer",
          expires_in: @expires_in,
          project_id: scope.active_project_id
        })

      {:error, changeset} ->
        Logger.error("[SpriteToken] could not mint a token: #{inspect(changeset.errors)}")

        conn
        |> put_status(:internal_server_error)
        |> json(%{error: "token_creation_failed"})
    end
  end
end
