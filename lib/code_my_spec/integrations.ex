defmodule CodeMySpec.Integrations do
  @moduledoc """
  Context module for managing OAuth provider integrations.

  Orchestrates OAuth flows using Assent strategies and provider implementations,
  persisting tokens and user metadata through the IntegrationRepository.

  ## OAuth Flow

  ### Request Phase
  1. User initiates connection to a provider (e.g., GitHub)
  2. `authorize_url/2` generates OAuth authorization URL
  3. User is redirected to provider for consent
  4. Session params are stored for callback verification

  ### Callback Phase
  1. Provider redirects back with authorization code
  2. `handle_callback/3` exchanges code for tokens
  3. Provider normalizes user data
  4. Integration is upserted with encrypted tokens

  ## Provider Support

  Providers must implement `CodeMySpec.Integrations.Providers.Behaviour`:
  - `config/0` - Returns Assent configuration
  - `strategy/0` - Returns Assent strategy module
  - `normalize_user/1` - Transforms provider user data to domain model
  """

  alias CodeMySpec.Integrations.{Integration, IntegrationRepository}
  alias CodeMySpec.Users.Scope

  @providers %{
    github: CodeMySpec.Integrations.Providers.GitHub,
    google: CodeMySpec.Integrations.Providers.Google
  }

  # Minimal scopes for social login — just enough for identity
  @login_scopes %{
    github: "user:email",
    google: "email profile"
  }

  @type provider :: :github | :gitlab | :bitbucket | :google
  @type oauth_params :: %{String.t() => String.t()}

  @doc """
  Generates OAuth authorization URL for the specified provider.

  Returns the authorization URL to redirect the user to and session params
  that must be stored and passed back during callback.

  ## Examples

      iex> authorize_url(:github)
      {:ok, %{url: "https://github.com/login/oauth/authorize?...", session_params: %{...}}}

      iex> authorize_url(:unsupported)
      {:error, :unsupported_provider}
  """
  @spec authorize_url(provider()) ::
          {:ok, %{url: String.t(), session_params: map()}} | {:error, term()}
  def authorize_url(provider) do
    with {:ok, provider_module} <- get_provider_module(provider),
         config <- provider_module.config(),
         strategy <- provider_module.strategy() do
      strategy.authorize_url(config)
    end
  end

  @doc """
  Handles OAuth callback and creates or updates integration.

  Exchanges authorization code for access token, normalizes user data,
  and upserts the integration for the authenticated user.

  ## Parameters
  - `scope` - User scope for multi-tenant isolation
  - `provider` - Provider identifier (:github, :gitlab, :bitbucket)
  - `callback_params` - Query params from OAuth callback including code and state
  - `session_params` - Session params from authorize_url that were stored

  ## Examples

      iex> handle_callback(scope, :github, %{"code" => "..."}, %{...})
      {:ok, %Integration{provider: :github}}

      iex> handle_callback(scope, :github, %{"error" => "access_denied"}, %{})
      {:error, "access_denied"}
  """
  @spec handle_callback(Scope.t(), provider(), oauth_params(), map()) ::
          {:ok, Integration.t()} | {:error, term()}
  def handle_callback(%Scope{} = scope, provider, callback_params, session_params) do
    with {:ok, provider_module} <- get_provider_module(provider),
         {:ok, token_response} <-
           exchange_code_for_token(provider_module, callback_params, session_params),
         {:ok, normalized_user} <- provider_module.normalize_user(token_response.user) do
      persist_integration(scope, provider, token_response, normalized_user)
    end
  end

  @doc """
  Retrieves integration for the scoped user and provider.

  Delegates to IntegrationRepository for data access.

  ## Examples

      iex> get_integration(scope, :github)
      {:ok, %Integration{provider: :github}}
  """
  @spec get_integration(Scope.t(), provider()) ::
          {:ok, Integration.t()} | {:error, :not_found}
  defdelegate get_integration(scope, provider), to: IntegrationRepository

  @doc """
  Lists all integrations for the scoped user.

  ## Examples

      iex> list_integrations(scope)
      [%Integration{provider: :github}, %Integration{provider: :gitlab}]
  """
  @spec list_integrations(Scope.t()) :: [Integration.t()]
  defdelegate list_integrations(scope), to: IntegrationRepository

  @doc """
  Removes integration for the scoped user and provider.

  ## Examples

      iex> delete_integration(scope, :github)
      {:ok, %Integration{}}
  """
  @spec delete_integration(Scope.t(), provider()) ::
          {:ok, Integration.t()} | {:error, :not_found}
  defdelegate delete_integration(scope, provider), to: IntegrationRepository

  @doc """
  Checks if user is connected to the specified provider.

  ## Examples

      iex> connected?(scope, :github)
      true
  """
  @spec connected?(Scope.t(), provider()) :: boolean()
  defdelegate connected?(scope, provider), to: IntegrationRepository

  ## Social Login Flow

  @doc """
  Generates OAuth authorization URL with minimal scopes for social login.

  Uses only identity scopes (email/profile) rather than the full integration
  scopes. Shares the same `/auth/:provider/callback` URL as integration connect.
  """
  @spec authorize_login_url(provider()) ::
          {:ok, %{url: String.t(), session_params: map()}} | {:error, term()}
  def authorize_login_url(provider) do
    with {:ok, provider_module} <- get_provider_module(provider) do
      config =
        provider_module.config()
        |> Keyword.update(:authorization_params, [], fn params ->
          params
          |> Keyword.put(:scope, @login_scopes[provider])
          |> Keyword.delete(:prompt)
        end)

      provider_module.strategy().authorize_url(config)
    end
  end

  @doc """
  Handles OAuth callback for social login.

  Exchanges the authorization code for tokens and normalizes the user data.
  Does NOT persist an integration — that happens after the user is found/created.
  """
  @spec handle_login_callback(provider(), oauth_params(), map()) ::
          {:ok, %{user: map(), token: map()}} | {:error, term()}
  def handle_login_callback(provider, callback_params, session_params) do
    with {:ok, provider_module} <- get_provider_module(provider) do
      config =
        provider_module.config()
        |> Keyword.put(:session_params, session_params)

      case provider_module.strategy().callback(config, callback_params) do
        {:ok, %{user: user, token: token}} ->
          with {:ok, normalized_user} <- provider_module.normalize_user(user) do
            {:ok, %{user: normalized_user, token: token}}
          end

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @doc """
  Persists an integration for a user after social login.

  Called after the user has been found or created, to store their OAuth
  tokens and provider metadata.
  """
  @spec save_integration(Scope.t(), provider(), map(), map()) ::
          {:ok, Integration.t()} | {:error, term()}
  def save_integration(%Scope{} = scope, provider, token, normalized_user) do
    persist_integration(scope, provider, token, normalized_user)
  end

  @doc """
  Refresh the stored access token for a provider integration.

  Calls the provider's `refresh_token` grant against its token endpoint and
  upserts the integration with the new `access_token`, `expires_at`, and —
  when the provider rotates them — a new `refresh_token`. Granted scopes
  and provider_metadata are preserved.

  ## Errors

  - `:not_found` — no integration exists for this user/provider
  - `:no_refresh_token` — integration was stored without a refresh_token
    (the user needs to re-authenticate)
  - other terms — provider returned an error (token revoked, etc.)
  """
  @spec refresh_token(Scope.t(), provider()) ::
          {:ok, Integration.t()} | {:error, :not_found | :no_refresh_token | term()}
  def refresh_token(%Scope{} = scope, provider) do
    with {:ok, integration} <- get_integration(scope, provider),
         {:ok, refresh_token} <- fetch_refresh_token(integration),
         {:ok, provider_module} <- get_provider_module(provider),
         {:ok, token_response} <- assent_refresh(provider_module, refresh_token) do
      persist_refreshed_token(scope, provider, integration, token_response)
    end
  end

  defp fetch_refresh_token(%Integration{refresh_token: rt}) when is_binary(rt) and rt != "",
    do: {:ok, rt}

  defp fetch_refresh_token(_), do: {:error, :no_refresh_token}

  defp assent_refresh(provider_module, refresh_token) do
    # Mirror Assent.Strategy.OAuth2.Base/OIDC.Base's set_config: strategy
    # defaults underneath, our provider config on top. Otherwise required
    # keys like :base_url (set by the strategy, not us) are missing because
    # we are calling refresh_access_token/3 directly.
    user_config = provider_module.config()

    config =
      user_config
      |> provider_module.strategy().default_config()
      |> Keyword.merge(user_config)

    Assent.Strategy.OAuth2.refresh_access_token(config, %{"refresh_token" => refresh_token})
  end

  defp persist_refreshed_token(scope, provider, integration, token_response) do
    attrs = %{
      access_token: token_response["access_token"],
      refresh_token: token_response["refresh_token"] || integration.refresh_token,
      expires_at: calculate_expires_at(token_response),
      granted_scopes: refreshed_scopes(token_response, integration),
      provider_metadata: integration.provider_metadata
    }

    IntegrationRepository.upsert_integration(scope, provider, attrs)
  end

  defp refreshed_scopes(token_response, integration) do
    case parse_scopes(token_response["scope"]) do
      [] -> integration.granted_scopes
      scopes -> scopes
    end
  end

  # Private Helpers

  defp get_provider_module(provider) do
    case Map.get(@providers, provider) do
      nil -> {:error, :unsupported_provider}
      module -> {:ok, module}
    end
  end

  defp exchange_code_for_token(provider_module, callback_params, session_params) do
    config =
      provider_module.config()
      |> Keyword.put(:session_params, session_params)

    strategy = provider_module.strategy()

    case strategy.callback(config, callback_params) do
      {:ok, %{user: user, token: token}} ->
        {:ok, Map.put(token, :user, user)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp persist_integration(scope, provider, token_response, normalized_user) do
    integration_attrs = %{
      access_token: token_response["access_token"],
      refresh_token: token_response["refresh_token"],
      expires_at: calculate_expires_at(token_response),
      granted_scopes: parse_scopes(token_response["scope"]),
      provider_metadata: normalized_user
    }

    IntegrationRepository.upsert_integration(scope, provider, integration_attrs)
  end

  defp calculate_expires_at(%{"expires_in" => expires_in}) when is_integer(expires_in) do
    DateTime.utc_now()
    |> DateTime.add(expires_in, :second)
  end

  defp calculate_expires_at(_), do: DateTime.utc_now() |> DateTime.add(365, :day)

  defp parse_scopes(nil), do: []
  defp parse_scopes(scope) when is_binary(scope), do: String.split(scope, ~r/[,\s]+/, trim: true)
  defp parse_scopes(scopes) when is_list(scopes), do: scopes
  defp parse_scopes(_), do: []
end
