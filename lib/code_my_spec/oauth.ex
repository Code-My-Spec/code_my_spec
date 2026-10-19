defmodule CodeMySpec.Oauth do
  @moduledoc """
  Public API for the OAuth2 authorization server.

  Wraps `ExOauth2Provider`-backed schemas (`Application`,
  `AccessToken`, `AccessGrant`) so the web tier doesn't reach into
  `Repo` directly. Currently exposes just the bits the OAuth /
  Dynamic Client Registration controllers need, plus the device
  authorization grant (RFC 8628).
  """

  use Boundary, top_level?: true, deps: [CodeMySpec.Repo, CodeMySpec.Users], exports: :all

  import Ecto.Query, only: [from: 2]

  alias CodeMySpec.Oauth.Application
  alias CodeMySpec.Oauth.DeviceGrant
  alias CodeMySpec.Repo
  alias CodeMySpec.Users.User
  alias ExOauth2Provider.AccessTokens
  alias ExOauth2Provider.Applications
  alias ExOauth2Provider.Config, as: OauthConfig

  @doc """
  Registers a new OAuth2 application (MCP client) with the given
  attributes. Returns `{:ok, %Application{}}` on success or
  `{:error, %Ecto.Changeset{}}` when the metadata fails validation.
  """
  @spec register_application(map()) ::
          {:ok, Application.t()} | {:error, Ecto.Changeset.t()}
  def register_application(attrs) do
    %Application{}
    |> Application.changeset(attrs)
    |> Repo.insert()
  end

  @device_code_ttl_seconds 600
  @device_code_interval 5

  @doc """
  Start a device-authorization request (RFC 8628) for the OAuth client
  named by `client_uid`.

  `device_id` travels through as an opaque value -- the harness's own
  self-chosen id, not something this context resolves or validates; a
  device shown on the devices page is that page's own lookup, not this
  one's job.

  Answers `{:error, :invalid_client}` when no such application is
  registered -- the caller, not an OAuth error code, decides how that
  reads to whoever asked.
  """
  @spec request_device_code(String.t(), String.t() | nil, keyword()) ::
          {:ok, DeviceGrant.t()} | {:error, :invalid_client} | {:error, Ecto.Changeset.t()}
  def request_device_code(client_uid, device_id, opts \\ []) when is_binary(client_uid) do
    case Applications.get_application(client_uid, otp_app: :code_my_spec) do
      nil ->
        {:error, :invalid_client}

      application ->
        application
        |> DeviceGrant.new_changeset(device_id,
          ttl_seconds: Keyword.get(opts, :ttl_seconds, @device_code_ttl_seconds),
          interval: Keyword.get(opts, :interval, @device_code_interval),
          scopes: Keyword.get(opts, :scopes)
        )
        |> Repo.insert()
    end
  end

  @doc "The pending grant a person is approving, by the code they typed in. `nil` if no such code exists."
  @spec get_device_grant_by_user_code(String.t()) :: DeviceGrant.t() | nil
  def get_device_grant_by_user_code(user_code) when is_binary(user_code) do
    user_code
    |> normalize_user_code()
    |> find_by_user_code()
  end

  @doc """
  The grant a person's confirm-page form names by its `device_code`, so a
  decision lands on the one it was shown for rather than a second lookup by
  the retyped `user_code`. `nil` if no such code exists.
  """
  @spec get_device_grant_by_device_code(String.t()) :: DeviceGrant.t() | nil
  def get_device_grant_by_device_code(device_code) when is_binary(device_code) do
    case Repo.get_by(DeviceGrant, device_code: device_code) do
      nil -> nil
      grant -> Repo.preload(grant, :application)
    end
  end

  defp find_by_user_code(code) do
    case Repo.get_by(DeviceGrant, user_code: code) do
      nil -> nil
      grant -> Repo.preload(grant, :application)
    end
  end

  defp normalize_user_code(code), do: code |> String.trim() |> String.upcase()

  @doc """
  Record the signed-in `user`'s decision on `grant`.

  Approving mints the access token immediately, bound to `user` and the
  grant's own application -- the one point in this flow where a full
  resource-owner struct is actually in hand, since the device itself
  never carries one. Refuses a grant that already expired or was already
  decided, so a stale tab's second click cannot resurrect or flip one.
  """
  @spec decide_device_grant(DeviceGrant.t(), User.t(), :approve | :deny) ::
          {:ok, DeviceGrant.t()}
          | {:error, :expired | :already_decided | Ecto.Changeset.t() | term()}
  def decide_device_grant(%DeviceGrant{} = grant, %User{} = user, :approve) do
    with :ok <- check_decidable(grant) do
      approve_and_mint(grant, user)
    end
  end

  def decide_device_grant(%DeviceGrant{} = grant, %User{}, :deny) do
    with :ok <- check_decidable(grant) do
      grant |> DeviceGrant.deny_changeset() |> Repo.update()
    end
  end

  defp check_decidable(grant) do
    cond do
      DeviceGrant.expired?(grant) -> {:error, :expired}
      DeviceGrant.denied?(grant) or DeviceGrant.approved?(grant) -> {:error, :already_decided}
      true -> :ok
    end
  end

  defp approve_and_mint(grant, user) do
    Repo.transaction(fn ->
      application = Repo.preload(grant, :application).application

      with {:ok, grant} <- grant |> DeviceGrant.approve_changeset(user.id) |> Repo.update(),
           {:ok, token} <-
             AccessTokens.create_token(
               user,
               %{
                 application: application,
                 scopes: grant.scopes,
                 # The library's own authorization_code/password strategies pass
                 # this explicitly (create_token/3 only issues a refresh token
                 # when told to) -- without it, a device grant's token had no
                 # way to renew and nothing to revoke, breaking John's "the
                 # harness keeps a refresh token bound to its own client" (point 3).
                 use_refresh_token: OauthConfig.use_refresh_token?(otp_app: :code_my_spec)
               },
               otp_app: :code_my_spec
             ),
           {:ok, grant} <- grant |> DeviceGrant.claim_changeset(token.id) |> Repo.update() do
        grant
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  @doc """
  The outcome of a client polling `device_code` for `client_uid`.

  Answers `{:ok, access_token}` once a person has approved it -- the token
  was minted at approval time, so this is purely a read, and polling the
  same code twice after approval answers the same token rather than
  minting another. `{:error, :authorization_pending}` while nobody has
  decided yet, `{:error, :access_denied}` if they declined,
  `{:error, :expired_token}` once the code's own deadline has passed, and
  `{:error, :invalid_grant}` for a code naming no grant, or one issued to a
  different client than the one polling -- RFC 8628 draws no distinction
  between "no such code" and "not yours" for exactly the reason an OAuth
  token endpoint never distinguishes "no such client" from "wrong secret".
  """
  @spec poll_device_grant(String.t(), String.t()) ::
          {:ok, ExOauth2Provider.AccessTokens.AccessToken.t()}
          | {:error, :authorization_pending | :access_denied | :expired_token | :invalid_grant}
  def poll_device_grant(device_code, client_uid)
      when is_binary(device_code) and is_binary(client_uid) do
    DeviceGrant
    |> Repo.get_by(device_code: device_code)
    |> preload_for_poll()
    |> resolve_poll(client_uid)
  end

  defp preload_for_poll(nil), do: nil
  defp preload_for_poll(grant), do: Repo.preload(grant, :application)

  defp resolve_poll(nil, _client_uid), do: {:error, :invalid_grant}

  defp resolve_poll(%DeviceGrant{application: %{uid: uid}}, client_uid) when uid != client_uid,
    do: {:error, :invalid_grant}

  defp resolve_poll(%DeviceGrant{} = grant, _client_uid) do
    cond do
      # Checked ahead of expiry/denial: a device_code already exchanged is
      # done regardless of what its own clock says next (RFC 8628 §3.5).
      DeviceGrant.consumed?(grant) -> {:error, :invalid_grant}
      DeviceGrant.expired?(grant) -> {:error, :expired_token}
      DeviceGrant.denied?(grant) -> {:error, :access_denied}
      DeviceGrant.approved?(grant) -> consume_and_fetch_token(grant)
      true -> {:error, :authorization_pending}
    end
  end

  # A device_code is single-use: once a client has successfully retrieved
  # the token, a second poll -- whether from the same client racing itself
  # or from anyone else who got hold of the code in the meantime -- answers
  # invalid_grant, same as a code nobody ever issued. The guard lives in the
  # UPDATE itself (`consumed_at IS NULL`), not in a read-then-write, so two
  # concurrent polls cannot both win it.
  defp consume_and_fetch_token(%DeviceGrant{} = grant) do
    query = from(g in DeviceGrant, where: g.id == ^grant.id and is_nil(g.consumed_at))

    case Repo.update_all(query, set: [consumed_at: DateTime.utc_now() |> DateTime.truncate(:second)]) do
      {1, _} -> fetch_claimed_token(grant)
      {0, _} -> {:error, :invalid_grant}
    end
  end

  # Approved always claims its token in the same transaction (`approve_and_mint/2`),
  # so a nil here means that transaction rolled back or never ran -- not a case
  # polling should paper over with a fresh mint.
  defp fetch_claimed_token(%DeviceGrant{access_token_id: id}) when is_integer(id) do
    case Repo.get(CodeMySpec.Oauth.AccessToken, id) do
      nil -> {:error, :invalid_grant}
      token -> {:ok, token}
    end
  end

  defp fetch_claimed_token(%DeviceGrant{}), do: {:error, :invalid_grant}
end
