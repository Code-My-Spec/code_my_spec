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

  ## Scopes

  Dot-separated (`zone.read`), NOT the colon form that Cloudflare's own
  API-token permissions use (`zone:read`). Every colon-form scope is rejected
  with `invalid_scope`, which is an easy hour to lose because the token UI
  shows the colon form.

  The names are also not derivable from the resource — it is
  `registrar-domains.admin`, not `registrar.edit`, and `dns.write`, not
  `dns_records.edit`. The full set below was confirmed against the live
  authorize endpoint, individually and together.

  There is no `account.read`. Zone creation needs an account id, so that has
  to come from somewhere other than a scope — the zone list, or the account
  the user picks during consent.

  ### Sandbox registrar

  `registrar-sandbox-domains.admin` / `.read` exist alongside the real ones.
  That is how the domain-registration path gets exercised end to end without
  spending money on a throwaway domain, which is worth preferring for
  anything that is not a deliberate production purchase.

  ### Not requested

  `cache.purge` is grantable but nothing here purges cache, so it is left out
  — an unused scope on a consent screen is a reason for a user to say no.

  ## Redirect URI

  The registered URIs are `https://codemyspec.com/auth/cloudflare/callback`
  and the `dev.` equivalent — confirmed by probing the authorize endpoint,
  which names a mismatch explicitly. Localhost is NOT registered, so a local
  OAuth round-trip has to come back through one of those hosts.
  """

  @behaviour CodeMySpec.Integrations.Providers.Behaviour

  # Every one verified against the live authorize endpoint. An unpermitted
  # scope fails the whole request rather than degrading, so do not add a
  # guessed name here — probe it first.
  @scopes ~w(
    zone.read
    zone.write
    dns.read
    dns.write
    registrar-domains.read
    registrar-domains.admin
    email-routing-address.write
    email-routing-rule.write
  )

  # Registration and DNS against Cloudflare's sandbox registrar, for
  # exercising the purchase path without buying a domain.
  @sandbox_scopes ~w(registrar-sandbox-domains.read registrar-sandbox-domains.admin)

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

  @doc "The scopes this integration requests."
  @spec scopes() :: [String.t()]
  def scopes, do: @scopes

  @doc """
  Sandbox registrar scopes, for exercising domain registration without buying
  a domain. Not requested by default — `config/0` asks for the real registrar,
  and a caller wanting the sandbox opts in.
  """
  @spec sandbox_scopes() :: [String.t()]
  def sandbox_scopes, do: @sandbox_scopes

  @doc """
  Config that grants the sandbox registrar alongside everything else.

  Use when driving the registration flow for a test or a recording rather than
  a real purchase.
  """
  @spec sandbox_config() :: Keyword.t()
  def sandbox_config do
    Keyword.update!(config(), :authorization_params, fn params ->
      Keyword.put(params, :scope, Enum.join(@scopes ++ @sandbox_scopes, " "))
    end)
  end

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
