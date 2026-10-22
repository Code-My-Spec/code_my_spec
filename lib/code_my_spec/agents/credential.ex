defmodule CodeMySpec.Agents.Credential do
  @moduledoc """
  Turning a stored integration into the entry Pi expects in `auth.json`.

  Pi holds exactly two credential kinds, keyed by provider id
  (`pi-ai/dist/auth/types.d.ts`):

      %{"type" => "oauth",   "refresh" => _, "access" => _, "expires" => _}
      %{"type" => "api_key", "key" => _}

  Every OAuth provider shares the first shape, so adding a provider is adding
  an integration, not a second way to start an agent.

  Failures stay distinct: `:not_connected` (nobody connected the provider) and
  `:reconnect_required` (its credential can no longer be refreshed, including
  a refresh token revoked as replay) want opposite remedies.

  See knowledge/agents/coordination, "Credentials".
  """

  alias CodeMySpec.Agents.Providers
  alias CodeMySpec.Integrations
  alias CodeMySpec.Users.Scope

  @type t :: %{String.t() => String.t() | integer()}

  @doc """
  The `auth.json` entry for one provider, or why there is not one.

  A `:local` provider (see `Providers`) short-circuits to `{:ok, %{}}`
  unconditionally — there is no Integration to check, no token to mint, and
  every account reads as "connected" for it; not yet scoped to specific
  accounts (see the TODO in `Providers`).
  """
  @spec fetch(Scope.t(), String.t()) ::
          {:ok, t()} | {:error, :not_connected | :reconnect_required | term()}
  def fetch(%Scope{} = scope, provider) when is_binary(provider) do
    case provider_kind(provider) do
      {:ok, :local} ->
        {:ok, %{}}

      {:ok, _kind} ->
        with {:ok, integration_provider} <- Providers.integration_provider(provider) do
          build_or_platform(scope, provider, integration_provider)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Desktop runs Codex on this machine's login, just like its local Claude CLI.
  # Hosted deployments retain their integration credential checks.
  defp provider_kind("openai-codex" = provider) do
    if Application.get_env(:code_my_spec, :env) == :desktop,
      do: {:ok, :local},
      else: Providers.kind(provider)
  end

  defp provider_kind(provider), do: Providers.kind(provider)

  defp build_or_platform(scope, provider, integration_provider) do
    case build(scope, provider, integration_provider) do
      {:error, :not_connected} -> platform_credential(provider)
      result -> result
    end
  end

  @doc """
  Ours, for a visitor who has connected nothing yet.

  Intake ends with the visitor talking to their project's agent, before they
  have connected a provider, so that first conversation runs on our key.

  Off unless `:platform_api_key` is configured. Bounded by
  `Agents.turn_allowance/2` (`:platform_turn_cap`, default 10 turns, enforced
  at `Agents.dispatch_message`); there is no token budget and no expiry. Only
  reached when the visitor's own integration is missing.
  """
  @spec platform_credential(String.t()) :: {:ok, t()} | {:error, :not_connected}
  def platform_credential(_provider) do
    # Trimmed: an unset env var arrives through config as `""` or spaces, which
    # is truthy and would hand out a credential made of whitespace.
    case config()[:platform_api_key] |> to_string() |> String.trim() do
      key when key != "" ->
        # The same two-key shape the connected path builds.
        {:ok, %{"type" => "api_key", "key" => key}}

      _ ->
        {:error, :not_connected}
    end
  end

  @doc """
  Whose credential an agent on this provider would run on.

  `:user` is theirs, `:platform` is ours, `:none` is nobody's — the agent cannot
  start at all.

  Separate from `fetch/2` because only the turn cap cares: it applies to
  exactly the agents we pay for. Derived, never stored, so a visitor who
  connects their own provider later stops being capped at once.
  """
  @spec source(Scope.t(), String.t()) :: :user | :platform | :none
  def source(%Scope{} = scope, provider) when is_binary(provider) do
    case provider_kind(provider) do
      # Never ours to pay for: the harness machine spends its own login.
      {:ok, :local} ->
        :user

      {:ok, _kind} ->
        source_via_integration(scope, provider)

      {:error, _reason} ->
        :none
    end
  end

  defp source_via_integration(scope, provider) do
    case Providers.integration_provider(provider) do
      {:ok, integration_provider} -> source_from_build(scope, provider, integration_provider)
      {:error, _reason} -> :none
    end
  end

  defp source_from_build(scope, provider, integration_provider) do
    case build(scope, provider, integration_provider) do
      {:ok, _credential} ->
        :user

      # A credential that needs reconnecting is still theirs; `fetch/2` does
      # not fall back to ours for it either.
      {:error, :reconnect_required} ->
        :user

      {:error, :not_connected} ->
        case platform_credential(provider) do
          {:ok, _} -> :platform
          {:error, _} -> :none
        end

      {:error, _other} ->
        :none
    end
  end

  defp config, do: Application.get_env(:code_my_spec, __MODULE__, [])

  defp build(scope, provider, integration_provider) do
    scope
    |> Integrations.fetch_access_token(integration_provider)
    |> to_credential(scope, provider, integration_provider)
  end

  defp to_credential({:error, :not_found}, _scope, _provider, _integration_provider),
    do: {:error, :not_connected}

  defp to_credential({:error, :reauthorize_required}, _scope, _provider, _integration_provider),
    do: {:error, :reconnect_required}

  # A refresh the provider refused (an exception, e.g. `invalid_grant` for a
  # superseded refresh token) is a credential that needs reconnecting.
  defp to_credential({:error, %{__exception__: true}}, _scope, _provider, _integration_provider),
    do: {:error, :reconnect_required}

  defp to_credential({:error, reason}, _scope, _provider, _integration_provider),
    do: {:error, reason}

  defp to_credential({:ok, token}, scope, provider, integration_provider) do
    provider
    |> Providers.credential_kind()
    |> entry(scope, token, integration_provider)
  end

  defp entry(:api_key, _scope, token, _integration_provider),
    do: {:ok, %{"type" => "api_key", "key" => token}}

  defp entry(:oauth, scope, token, integration_provider) do
    scope
    |> Integrations.get_integration(integration_provider)
    |> oauth_entry(token)
  end

  defp oauth_entry({:ok, integration}, token) do
    {:ok,
     %{
       "type" => "oauth",
       "access" => token,
       "refresh" => integration.refresh_token || "",
       "expires" => expires_ms(integration.expires_at)
     }
     |> put_account_id(token)
     |> put_id_token(integration)
     |> put_refreshed_at(integration)}
  end

  defp oauth_entry({:error, reason}, _token), do: {:error, reason}

  # When this token was last renewed (the integration's `updated_at`), so the
  # reader does not renew it on startup and rotate the refresh token out from
  # under every other copy. Both datetime kinds are accepted.
  # See knowledge/agents/coordination, "Credentials".
  defp put_refreshed_at(entry, %{updated_at: %DateTime{} = at}),
    do: Map.put(entry, "refreshedAt", DateTime.to_iso8601(at))

  defp put_refreshed_at(entry, %{updated_at: %NaiveDateTime{} = at}) do
    Map.put(entry, "refreshedAt", at |> DateTime.from_naive!("Etc/UTC") |> DateTime.to_iso8601())
  end

  defp put_refreshed_at(entry, _integration), do: entry

  # The OIDC id token, from `provider_metadata` (`Integrations.keep_id_token/2`):
  # `codex exec` refuses an `auth.json` without one.
  defp put_id_token(entry, %{provider_metadata: %{"id_token" => token}})
       when is_binary(token) and token != "",
       do: Map.put(entry, "idToken", token)

  defp put_id_token(entry, _integration), do: entry

  # OpenAI's account id, sent as the `chatgpt-account-id` header on every model
  # call; without it the first request fails. Decoded from the access token's
  # JWT so a refreshed token brings its own. No claim, no key.
  defp put_account_id(entry, token) do
    case account_id(token) do
      nil -> entry
      account_id -> Map.put(entry, "accountId", account_id)
    end
  end

  defp account_id(token) when is_binary(token) do
    with [_header, payload, _signature] <- String.split(token, "."),
         {:ok, json} <- Base.url_decode64(payload, padding: false),
         {:ok, claims} <- Jason.decode(json) do
      claims |> Map.get("https://api.openai.com/auth", %{}) |> Map.get("chatgpt_account_id")
    else
      _ -> nil
    end
  end

  defp account_id(_token), do: nil

  # Epoch milliseconds: seconds would read as 1970 and every token as expired.
  defp expires_ms(%DateTime{} = expires_at), do: DateTime.to_unix(expires_at, :millisecond)
  defp expires_ms(nil), do: 0
end
