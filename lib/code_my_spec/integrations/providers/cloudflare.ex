defmodule CodeMySpec.Integrations.Providers.Cloudflare do
  @moduledoc """
  Cloudflare OAuth provider — delegated access to a user's own Cloudflare
  account for domain registration, DNS and zone management.

  ## Why OAuth rather than an API token

  Provisioning acts on Sam's Cloudflare account, not ours. A static API token
  pasted into config would have to be *his* token, stored by us, with whatever
  permissions he happened to grant it and no way to revoke it from Cloudflare's
  side. Delegated access is revocable by him, scoped per-grant, and never gives
  us a credential he cannot take back.

  ## PKCE is required, not optional

  Cloudflare rejects an authorize request without `code_challenge` — verified
  against the live endpoint, which answers `invalid_request` for a call that
  omits it. Hence `code_verifier: true`.

  ## Scopes — dot-separated, and currently narrower than provisioning needs

  Cloudflare's OAuth scopes use dot notation (`zone.read`), NOT the colon form
  that its API-token permissions use (`zone:read`). Every colon-form scope is
  rejected with `invalid_scope`.

  More importantly: this client's registered allow-list is `zone.read` and
  nothing else. Probed against the live authorize endpoint, all of these come
  back "The OAuth 2.0 Client is not allowed to request scope ...":

      zone.edit  zone.write  zone.create  dns_records.read  dns_records.edit
      account.read  user.read  registrar.read  registrar.edit  offline_access

  So the grant is **read-only** today. Provisioning needs zone creation, DNS
  record writes and Registrar access, none of which this client may request —
  widening it is a change to the app registration held with Cloudflare, not
  something callers can work around. Until then the write-path steps cannot
  run on a delegated token.

  Omitting `scope` entirely is also accepted and falls back to the client's
  registered default, but we send it explicitly so a widened registration
  shows up here as a deliberate change rather than silently altering what
  users consent to.

  ## Redirect URI

  The registered URIs are `https://codemyspec.com/auth/cloudflare/callback`
  and the `dev.` equivalent — confirmed by probing the authorize endpoint,
  which names a mismatch explicitly. Localhost is NOT registered, so a local
  OAuth round-trip has to come back through one of those hosts.
  """

  @behaviour CodeMySpec.Integrations.Providers.Behaviour

  # What the registration actually permits. See the scope note above before
  # adding to this list — an unpermitted scope fails the whole authorize
  # request, it does not degrade.
  @scopes ~w(zone.read)

  # What the provisioning steps need. Kept next to the granted set so the gap
  # is visible at the point someone would try to use them.
  @required_for_provisioning ~w(zone.read zone.edit dns_records.edit account.read registrar.edit)

  @impl true
  def config do
    [
      client_id: Application.fetch_env!(:code_my_spec, :cloudflare_client_id),
      client_secret: Application.fetch_env!(:code_my_spec, :cloudflare_client_secret),
      base_url: "https://dash.cloudflare.com",
      authorize_url: "/oauth2/auth",
      token_url: "/oauth2/token",
      user_url: "https://api.cloudflare.com/client/v4/user",
      auth_method: :client_secret_post,
      # Cloudflare rejects an authorize request with no code_challenge.
      code_verifier: true,
      redirect_uri: build_redirect_uri(),
      authorization_params: [
        scope: Enum.join(@scopes, " ")
      ]
    ]
  end

  @impl true
  def strategy, do: Assent.Strategy.OAuth2

  @doc "The scopes this integration requests — what the registration permits."
  @spec scopes() :: [String.t()]
  def scopes, do: @scopes

  @doc """
  Scopes the provisioning steps need, granted or not.

  `missing_scopes/0` is the difference — non-empty means the write-path steps
  (zone create, DNS records, domain registration) cannot run on a delegated
  token and the app registration has to be widened with Cloudflare first.
  """
  @spec required_for_provisioning() :: [String.t()]
  def required_for_provisioning, do: @required_for_provisioning

  @doc "Scopes provisioning needs that this client may not request."
  @spec missing_scopes() :: [String.t()]
  def missing_scopes, do: @required_for_provisioning -- @scopes

  # Cloudflare wraps every response in {success, errors, result}, so the
  # identity fields sit one level down rather than at the top like GitHub's.
  @impl true
  def normalize_user(%{"result" => result}) when is_map(result) do
    {:ok,
     %{
       provider_user_id: result["id"],
       email: result["email"],
       name: full_name(result),
       username: result["username"]
     }}
  end

  def normalize_user(user) when is_map(user) do
    {:ok,
     %{
       provider_user_id: user["id"] || user["sub"],
       email: user["email"],
       name: user["name"],
       username: user["username"]
     }}
  end

  def normalize_user(_), do: {:error, :invalid_user_data}

  defp full_name(%{"first_name" => first, "last_name" => last})
       when is_binary(first) and is_binary(last) do
    String.trim("#{first} #{last}")
  end

  defp full_name(result), do: result["name"]

  defp build_redirect_uri do
    "#{CodeMySpec.PublicUrl.base()}/auth/cloudflare/callback"
  end
end
