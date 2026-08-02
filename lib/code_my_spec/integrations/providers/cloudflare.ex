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

  There is no `account.read`, and that has a consequence beyond zone creation:
  `GET /client/v4/user` answers 403 (code 9109, "Unauthorized to access
  requested resource") on a delegated token, so it cannot serve as the
  identity endpoint. Confirmed on a real token — the exchange succeeds and
  only the user fetch fails, which makes it an easy failure to misread as a
  broken grant.

  `user_url` is therefore `/client/v4/zones`, which `zone.read` covers. The
  zone list doubles as the account id source that zone creation needs.

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
      user_url: "https://api.cloudflare.com/client/v4/zones",
      auth_method: :client_secret_post,
      # Cloudflare rejects an authorize request with no code_challenge.
      code_verifier: true,
      redirect_uri: build_redirect_uri(),
      authorization_params: [
        scope: Enum.join(scopes(), " ")
      ]
    ]
  end

  @impl true
  def strategy, do: Assent.Strategy.OAuth2

  @doc """
  The scopes this integration requests.

  ## Why `offline_access` is not in the list by default

  Without it Cloudflare issues no refresh token, so the grant dies at its
  expiry with nothing to renew from — which is what happened to the first
  connection here: no refresh token stored, and by the time anything needed
  it the grant was already dead.

  ## How to make a client that allows it

  `offline_access` is not a scope you select — it is not among the 381
  permission names `GET /oauth/scopes` returns, which is why hunting for it in
  the dashboard's scope picker finds nothing.

  Cloudflare adds it to a client's scopes *automatically* when the client
  carries `refresh_token` in its **grant types**. So the setting to change is
  the grant type, not the scope list:

      grant_types: ["authorization_code", "refresh_token"]
      -> scopes come back with "offline_access" appended

  Verified 2026-07-31: with `authorization_code` alone the authorize endpoint
  answers `invalid_scope` — "The OAuth 2.0 Client is not allowed to request
  scope 'offline_access'" — and with both grant types the same request is
  accepted. Grant types can be edited on an existing client; a new one is not
  required.

  It was off by default because Cloudflare rejects it unless the *client
  registration* carries it, and the original one did not:

      scope=offline_access  → invalid_scope, "The OAuth 2.0 Client is not
                              allowed to request scope 'offline_access'"
      scope=offline         → the same
      scope=<base scopes>   → accepted

  Both were probed against `dash.cloudflare.com/oauth2/auth` directly. The
  authorization server supports them — its discovery document lists
  `offline_access`, `offline` and `openid` under `scopes_supported`, and
  `refresh_token` under `grant_types_supported` — so this is a property of the
  client, not of Cloudflare.

  Requesting it unconditionally against a client that disallows it makes
  Cloudflare impossible to connect at all, which is strictly worse than a
  token that has to be re-granted — so the flag stays, and points at whether
  the configured client was created with the refresh grant.
  """
  @spec scopes() :: [String.t()]
  def scopes do
    if Application.get_env(:code_my_spec, :cloudflare_offline_access, false) do
      ["offline_access" | @scopes]
    else
      @scopes
    end
  end

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

  # The zone list stands in for identity, because no granted scope can read
  # the user. Each zone carries its account, which is what zone creation
  # needs and what no scope grants directly.
  @impl true
  def normalize_user(%{"result" => zones}) when is_list(zones) do
    accounts =
      zones
      |> Enum.map(& &1["account"])
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq_by(& &1["id"])

    {:ok,
     %{
       provider_user_id: accounts |> List.first() |> account_id(),
       email: nil,
       name: accounts |> List.first() |> account_name(),
       accounts: Enum.map(accounts, &%{id: &1["id"], name: &1["name"]}),
       zones: Enum.map(zones, & &1["name"])
     }}
  end

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

  defp account_id(nil), do: nil
  defp account_id(account), do: account["id"]

  defp account_name(nil), do: "Cloudflare account"
  defp account_name(account), do: account["name"]

  defp build_redirect_uri do
    "#{CodeMySpec.PublicUrl.base()}/auth/cloudflare/callback"
  end
end
