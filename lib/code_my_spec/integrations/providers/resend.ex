defmodule CodeMySpec.Integrations.Providers.Resend do
  @moduledoc """
  Resend OAuth provider — delegated access to a user's own Resend account for
  sending domains, DNS record sets and inbound routing.

  Same argument as `CodeMySpec.Integrations.Providers.Cloudflare`: provisioning
  acts on Sam's account, so the credential should be his to revoke.

  ## Discovery

  Resend publishes OAuth 2.1 metadata at
  `https://api.resend.com/.well-known/oauth-authorization-server`, which is
  where the endpoints below come from rather than from documentation prose:

      authorization_endpoint  https://api.resend.com/oauth/authorize
      token_endpoint          https://api.resend.com/oauth/token
      registration_endpoint   https://api.resend.com/oauth/register
      revocation_endpoint     https://api.resend.com/oauth/revoke

  It also supports unauthenticated dynamic client registration — a `POST` to
  the registration endpoint with no credentials returns a usable `client_id`.
  We use a pre-registered client instead, because a client minted at runtime
  cannot be revoked or audited by name, but the dynamic path is the fallback
  if the configured client is ever lost.

  ## Scopes

  `scopes_supported` is exactly `["full_access", "emails:send"]` — coarse.
  There is no scope that grants domain management without also granting
  everything else, so provisioning has to request `full_access` to create and
  verify a sending domain. Worth knowing rather than discovering later: this
  is a broader grant than the Cloudflare one, and not because we chose it.

  ## Refresh tokens rotate

  Resend returns a new refresh token on each refresh. `Integrations.
  refresh_token/2` already persists `token_response["refresh_token"]` when
  present, so rotation is handled — but a caller that caches the old one will
  find it dead.
  """

  @behaviour CodeMySpec.Integrations.Providers.Behaviour

  # Domain creation and verification are not reachable under `emails:send`.
  @scopes ~w(full_access)

  @impl true
  def config do
    [
      client_id: Application.fetch_env!(:code_my_spec, :resend_client_id),
      client_secret: Application.fetch_env!(:code_my_spec, :resend_client_secret),
      base_url: "https://api.resend.com",
      authorize_url: "/oauth/authorize",
      token_url: "/oauth/token",
      user_url: "https://api.resend.com/domains",
      auth_method: :client_secret_post,
      code_verifier: true,
      redirect_uri: build_redirect_uri(),
      authorization_params: [
        scope: Enum.join(@scopes, " ")
      ]
    ]
  end

  @impl true
  def strategy, do: Assent.Strategy.OAuth2

  @doc "The scopes this integration requests."
  @spec scopes() :: [String.t()]
  def scopes, do: @scopes

  # Resend has no user endpoint — the API is account-keyed with no /me. The
  # closest thing to identity is the set of domains the grant can see, so the
  # integration records that rather than inventing a user id. A grant with no
  # domains yet is legitimate (a fresh account), so it must not error.
  @impl true
  def normalize_user(%{"data" => domains}) when is_list(domains) do
    {:ok,
     %{
       provider_user_id: nil,
       email: nil,
       name: "Resend account",
       domains: Enum.map(domains, & &1["name"])
     }}
  end

  def normalize_user(user) when is_map(user) do
    {:ok,
     %{
       provider_user_id: user["id"],
       email: user["email"],
       name: user["name"] || "Resend account"
     }}
  end

  def normalize_user(_), do: {:error, :invalid_user_data}

  defp build_redirect_uri do
    "#{CodeMySpec.PublicUrl.base()}/auth/resend/callback"
  end
end
