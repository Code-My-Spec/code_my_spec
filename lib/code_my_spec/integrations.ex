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

  alias Assent.Strategy.OAuth2
  alias CodeMySpec.Integrations.{Integration, IntegrationRepository}
  alias CodeMySpec.Integrations.Providers.ApiKey
  alias CodeMySpec.Repo
  alias CodeMySpec.Users.Scope

  @providers %{
    github: CodeMySpec.Integrations.Providers.GitHub,
    google: CodeMySpec.Integrations.Providers.Google,
    cloudflare: CodeMySpec.Integrations.Providers.Cloudflare,
    resend: CodeMySpec.Integrations.Providers.Resend,
    openai: CodeMySpec.Integrations.Providers.OpenAI
  }

  # Minimal scopes for social login — just enough for identity. Deliberately
  # excludes :cloudflare and :resend: those exist to provision infrastructure
  # on the user's behalf, and nobody should be able to sign in with them.
  # `authorize_login_url/1` on either yields a nil scope, which the provider
  # would send as an empty grant.
  @login_scopes %{
    github: "user:email",
    google: "email profile"
  }

  # Refreshed this long before the stated expiry. Long enough to cover a slow
  # request that starts just before the boundary, short enough not to throw
  # away most of a fifteen-minute token.
  @refresh_skew_seconds 120

  @type provider :: :github | :gitlab | :bitbucket | :google | :cloudflare | :resend
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

  ## API-key Providers

  @doc """
  Connect a provider by the key someone pasted, once the provider says it works.

  The key is asked about before it is stored, and a refusal stores nothing —
  otherwise the settings page reports a connection whose first evidence is an
  agent failing a model call minutes later. `ApiKey.verify/2` distinguishes a
  key the provider refused from a provider that did not answer, and both are
  passed through: they read alike and want opposite responses.

  Stored the way GitHub's token is — no refresh token, an expiry a year out —
  because that is what a credential nobody can renew on the user's behalf looks
  like, and `fetch_access_token/2` already takes the fresh path for it.
  """
  @spec connect_api_key(Scope.t(), atom(), String.t()) ::
          {:ok, Integration.t()} | {:error, ApiKey.failure() | term()}
  def connect_api_key(%Scope{} = scope, provider, key) when is_binary(key) do
    trimmed = String.trim(key)

    with :ok <- present(trimmed),
         :ok <- ApiKey.verify(provider, trimmed) do
      IntegrationRepository.upsert_integration(scope, provider, %{
        access_token: trimmed,
        refresh_token: nil,
        expires_at: DateTime.utc_now() |> DateTime.add(365, :day),
        granted_scopes: [],
        provider_metadata: %{}
      })
    end
  end

  defp present(""), do: {:error, :blank}
  defp present(_key), do: :ok

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
  A token that is valid *now*, refreshing first if it is about to expire.

  This is what provider code should call. `get_integration/2` hands back
  whatever is stored, which for a short-lived grant is frequently a dead
  token — Resend's access tokens live fifteen minutes, so every call would
  401 a quarter of an hour after the user connected.

  ## Refreshed early, on purpose

  A token is treated as stale `#{@refresh_skew_seconds}` seconds before it
  actually expires. Checking against the exact instant passes a token with two
  seconds left and then fails inside the request that used it — a failure that
  depends on timing, appears under load, and cannot be reproduced.

  ## One refresh at a time, per grant

  The refresh happens under a row lock on the integration, and re-checks after
  taking it. Providers that rotate refresh tokens — Resend rotates on every
  use — invalidate the old value, so two concurrent refreshes mean the loser
  presents a spent token. That does not merely fail: it can revoke the grant,
  and the user has to reconnect.

  The provider HTTP call therefore happens while the lock is held. That is the
  point rather than an oversight; the alternative is a race that costs the
  user their connection.

  ## Errors

  - `:not_found` — no integration for this user and provider
  - `:reauthorize_required` — expired with no refresh token to renew it, so
    the only fix is the user reconnecting
  - other terms — the provider refused the refresh
  """
  @spec fetch_access_token(Scope.t(), provider()) ::
          {:ok, String.t()} | {:error, :not_found | :reauthorize_required | term()}
  def fetch_access_token(%Scope{} = scope, provider) do
    with {:ok, integration} <- get_integration(scope, provider) do
      cond do
        fresh?(integration) ->
          {:ok, integration.access_token}

        is_nil(integration.refresh_token) or integration.refresh_token == "" ->
          stale_without_refresh(integration)

        true ->
          refresh_serialized(scope, provider)
      end
    end
  end

  @doc """
  Whether a stored token is still usable, with the same margin
  `fetch_access_token/2` applies.
  """
  @spec fresh?(Integration.t()) :: boolean()
  def fresh?(%Integration{expires_at: %DateTime{} = expires_at}) do
    DateTime.compare(
      DateTime.utc_now(),
      DateTime.add(expires_at, -@refresh_skew_seconds, :second)
    ) ==
      :lt
  end

  # No refresh token, so there is nothing to renew with. GitHub is the
  # ordinary case: its user tokens carry no refresh token and are stored with
  # an expiry a year out, so they take the fresh path and never reach here.
  # One that has genuinely run out is the user's to reconnect, and saying so
  # is more useful than a 401 surfacing from somewhere deeper.
  defp stale_without_refresh(%Integration{} = integration) do
    if DateTime.compare(DateTime.utc_now(), integration.expires_at) == :lt do
      {:ok, integration.access_token}
    else
      {:error, :reauthorize_required}
    end
  end

  defp refresh_serialized(scope, provider) do
    Repo.transaction(fn ->
      case IntegrationRepository.lock_integration(scope, provider) do
        {:ok, integration} ->
          # Re-check under the lock: whoever held it before us may have just
          # refreshed, and burning a second rotation would spend a token that is
          # now the only valid one.
          if fresh?(integration) do
            integration.access_token
          else
            case refresh_locked(scope, provider, integration) do
              {:ok, refreshed} -> refreshed.access_token
              {:error, reason} -> Repo.rollback(reason)
            end
          end

        {:error, reason} ->
          Repo.rollback(reason)
      end
    end)
  end

  defp refresh_locked(scope, provider, integration) do
    with {:ok, refresh_token} <- fetch_refresh_token(integration),
         {:ok, provider_module} <- get_provider_module(provider),
         {:ok, token_response} <- assent_refresh(provider_module, refresh_token) do
      persist_refreshed_token(scope, provider, integration, token_response)
    end
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
    #
    # Only named strategies define default_config/1. Providers that use
    # `Assent.Strategy.OAuth2` directly — Cloudflare and Resend — have no
    # defaults to merge, and calling it on them raises UndefinedFunctionError.
    # This was written against Google, the only strategy that has one, so
    # refreshing either of the others crashed rather than failing: found the
    # first time a Resend token actually needed renewing.
    user_config = provider_module.config()
    strategy = provider_module.strategy()

    config =
      if Code.ensure_loaded?(strategy) and function_exported?(strategy, :default_config, 1) do
        user_config |> strategy.default_config() |> Keyword.merge(user_config)
      else
        user_config
      end

    OAuth2.refresh_access_token(config, %{"refresh_token" => refresh_token})
  end

  defp persist_refreshed_token(scope, provider, integration, token_response) do
    attrs = %{
      access_token: token_response["access_token"],
      refresh_token: token_response["refresh_token"] || integration.refresh_token,
      expires_at: calculate_expires_at(token_response),
      granted_scopes: refreshed_scopes(token_response, integration),
      provider_metadata: keep_id_token(integration.provider_metadata, token_response)
    }

    IntegrationRepository.upsert_integration(scope, provider, attrs)
  end

  # The OIDC id token, kept because one consumer cannot work without it.
  #
  # `codex exec` reads its credentials from an `auth.json` and refuses one that
  # has no `id_token` — literally, "missing field `id_token`", before any
  # network call. So a ChatGPT subscription that reaches an agent without it
  # cannot run a turn, however valid the access and refresh tokens are.
  # Established by running the binary against a hand-built file rather than
  # inferred: without the field it is rejected outright, with it the file is
  # accepted and proceeds to a real auth attempt.
  #
  # Kept in `provider_metadata` rather than given a column. It belongs to one
  # provider, it is not a credential we present anywhere ourselves, and a column
  # would invite every other provider to leave it null.
  #
  # Only when the response carries one. A refresh that returns no `id_token`
  # leaves the stored one alone rather than blanking it: the previous one is
  # still the identity of the same grant, and replacing it with nothing would
  # break the agent on the next launch for no reason.
  defp keep_id_token(metadata, token_response) do
    metadata = metadata || %{}

    case token_response["id_token"] do
      token when is_binary(token) and token != "" -> Map.put(metadata, "id_token", token)
      _ -> metadata
    end
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

  # A response with no refresh_token must never erase the stored one.
  #
  # Google omits `refresh_token` from every grant that is not a fresh consent,
  # and the social-login flow deliberately drops `prompt=consent` — so signing
  # in with Google returned a token response with no refresh_token, and this
  # wrote that nil straight over a working one. The integration then had no way
  # to renew and simply died at its next expiry.
  #
  # Keeping the old value is safe in a way that overwriting is not: a refresh
  # token stays valid until it is used or revoked, so the worst case is a stale
  # value that fails a refresh, versus certainly having none at all.
  defp persist_integration(scope, provider, token_response, normalized_user) do
    existing =
      case get_integration(scope, provider) do
        {:ok, integration} -> integration
        _ -> nil
      end

    integration_attrs = %{
      access_token: token_response["access_token"],
      refresh_token: token_response["refresh_token"] || (existing && existing.refresh_token),
      expires_at: calculate_expires_at(token_response),
      granted_scopes: merge_scopes(parse_scopes(token_response["scope"]), existing),
      provider_metadata: keep_id_token(normalized_user, token_response)
    }

    IntegrationRepository.upsert_integration(scope, provider, integration_attrs)
  end

  # Scopes accumulate rather than replace. Signing in with Google asks for
  # `email profile` and nothing else, and recording only those would report
  # that a grant which still carries the provisioning scopes no longer does —
  # `connected?/2`-style checks would then refuse work the grant can actually
  # do. Authorising a subset does not revoke what was granted before.
  defp merge_scopes(granted, nil), do: granted

  defp merge_scopes(granted, %Integration{granted_scopes: previous}) do
    (granted ++ List.wrap(previous)) |> Enum.uniq()
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
