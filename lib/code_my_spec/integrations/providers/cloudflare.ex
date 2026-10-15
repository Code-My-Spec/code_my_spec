defmodule CodeMySpec.Integrations.Providers.Cloudflare do
  @moduledoc """
  Cloudflare OAuth provider — delegated access to a user's own Cloudflare
  account for domain registration, DNS and zone management.

  Delegated OAuth rather than a pasted API token, so the user can revoke it
  from Cloudflare's side. PKCE is required (`code_verifier: true`).

  Scopes are dot-separated (`zone.read`), not the API-token colon form, and
  were each verified against the live authorize endpoint. No scope reads the
  user (`GET /client/v4/user` answers 403 on a delegated token), so `user_url`
  is the zone list, which also supplies the account id.

  The registered redirect URIs are `codemyspec.com` and `dev.codemyspec.com`
  `/auth/cloudflare/callback`; localhost is not registered.
  See knowledge/infrastructure, "Cloudflare OAuth".
  """

  @behaviour CodeMySpec.Integrations.Providers.Behaviour

  # An unpermitted scope fails the whole request, so do not add a guessed name
  # here — probe the live authorize endpoint first.
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

  `offline_access` (needed for a refresh token) is prepended only when
  `:cloudflare_offline_access` is set: Cloudflare rejects it with
  `invalid_scope` unless the OAuth client's grant types include
  `refresh_token`, and requesting it against such a client makes Cloudflare
  impossible to connect. See knowledge/infrastructure, "Cloudflare OAuth".
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
