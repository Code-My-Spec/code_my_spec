defmodule CodeMySpec.Integrations.Providers.Google do
  @moduledoc """
  Google provider implementation for OAuth integration.

  Implements the `CodeMySpec.Integrations.Providers.Behaviour` to provide
  Google-specific OAuth configuration using Assent's built-in Google strategy
  and normalizes Google user data to the application's domain model.

  ## Configuration

  Requires the following application config:
  - `:google_client_id` - OAuth client ID from Google Cloud Console
  - `:google_client_secret` - OAuth client secret from Google Cloud Console
  - Callback URL derived from `CodeMySpecWeb.Endpoint.url()`

  ## OAuth Flow

  This provider leverages `Assent.Strategy.Google` for OAuth implementation,
  providing only Google-specific configuration and user data normalization.

  ## Scopes

  The requested OAuth scopes are configured **per environment** via
  `config :code_my_spec, google_oauth_scopes: "<space-separated scopes>"`.
  The default (`"email profile"`) requests only the non-sensitive `email`
  and `profile` scopes, so the consent screen does not require Google app
  verification.

  Sensitive scopes (`https://www.googleapis.com/auth/adwords`,
  `https://www.googleapis.com/auth/analytics.edit`, etc.) force the app
  through Google's verification process (the "Google hasn't verified this
  app" warning). Add them only in environments where the app is verified —
  e.g. `config/dev.exs` enables the `adwords` scope for Google Ads testing
  while production stays on the verification-safe default until verified.
  """

  @behaviour CodeMySpec.Integrations.Providers.Behaviour

  # Verification-safe default — non-sensitive scopes only. Per-environment
  # config (`:google_oauth_scopes`) adds sensitive scopes where appropriate.
  @default_scopes "email profile"

  @impl true
  def config do
    require Logger

    client_id = Application.fetch_env!(:code_my_spec, :google_client_id)
    client_secret = Application.fetch_env!(:code_my_spec, :google_client_secret)
    redirect_uri = build_redirect_uri()

    Logger.debug("Google OAuth Config - client_id: #{inspect(client_id)}")
    Logger.debug("Google OAuth Config - client_secret present: #{!is_nil(client_secret)}")
    Logger.debug("Google OAuth Config - redirect_uri: #{redirect_uri}")

    [
      client_id: client_id,
      client_secret: client_secret,
      redirect_uri: redirect_uri,
      # Login flow lets OIDC discovery overwrite this; refresh flow uses it
      # directly because refresh_access_token/3 does not redo discovery.
      token_url: "https://oauth2.googleapis.com/token",
      auth_method: :client_secret_post,
      authorization_params: [
        scope: scopes(),
        access_type: "offline",
        prompt: "consent"
      ]
    ]
  end

  # The space-separated OAuth scope string, configured per environment.
  defp scopes do
    Application.get_env(:code_my_spec, :google_oauth_scopes, @default_scopes)
  end

  @impl true
  def strategy, do: Assent.Strategy.Google

  @impl true
  def normalize_user(user_data) when is_map(user_data) do
    with {:ok, provider_user_id} <- extract_provider_user_id(user_data) do
      {:ok,
       %{
         provider_user_id: provider_user_id,
         email: Map.get(user_data, "email"),
         name: Map.get(user_data, "name"),
         username: Map.get(user_data, "email"),
         avatar_url: Map.get(user_data, "picture"),
         hosted_domain: Map.get(user_data, "hd")
       }}
    end
  end

  def normalize_user(_), do: {:error, :invalid_user_data}

  defp extract_provider_user_id(user_data) do
    case Map.get(user_data, "sub") do
      nil -> {:error, :missing_provider_user_id}
      id when is_binary(id) -> {:ok, id}
      id when is_integer(id) -> {:ok, to_string(id)}
      _ -> {:error, :invalid_provider_user_id}
    end
  end

  defp build_redirect_uri do
    "#{CodeMySpec.PublicUrl.base()}/auth/google/callback"
  end
end
