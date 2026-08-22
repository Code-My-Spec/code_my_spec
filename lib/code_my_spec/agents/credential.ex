defmodule CodeMySpec.Agents.Credential do
  @moduledoc """
  Turning a stored integration into the entry Pi expects in `auth.json`.

  Pi holds exactly two credential kinds, keyed by provider id
  (`pi-ai/dist/auth/types.d.ts`):

      %{"type" => "oauth",   "refresh" => _, "access" => _, "expires" => _}
      %{"type" => "api_key", "key" => _}

  Every OAuth provider shares the first shape, so there is no per-provider token
  model to write — which is the whole reason adding a provider is adding an
  integration rather than a second way to start an agent.

  ## Why the three-way answer matters

  `Integrations.fetch_access_token/2` already distinguishes the two failures
  that must not be collapsed: `:not_found` is a provider nobody ever connected,
  `:reauthorize_required` is one whose credential can no longer be refreshed.
  They read alike and want opposite responses — the first sends someone to
  connect a provider, the second to reconnect one they know they connected, and
  telling them the wrong one sends them to set up something that already exists.

  That second state is also the shape refresh-token replay revocation arrives
  in. OpenAI rotates the refresh token on every refresh, so two working copies
  seeded from one credential can refresh out of order; if the provider treats
  the superseded token as replay it revokes the grant, and every copy discovers
  it here, long after the event.
  """

  alias CodeMySpec.Agents.Providers
  alias CodeMySpec.Integrations
  alias CodeMySpec.Users.Scope

  @type t :: %{String.t() => String.t() | integer()}

  @doc """
  The `auth.json` entry for one provider, or why there is not one.
  """
  @spec fetch(Scope.t(), String.t()) ::
          {:ok, t()} | {:error, :not_connected | :reconnect_required | term()}
  def fetch(%Scope{} = scope, provider) when is_binary(provider) do
    with {:ok, integration_provider} <- Providers.integration_provider(provider) do
      build(scope, provider, integration_provider)
    end
  end

  defp build(scope, provider, integration_provider) do
    scope
    |> Integrations.fetch_access_token(integration_provider)
    |> to_credential(scope, provider, integration_provider)
  end

  defp to_credential({:error, :not_found}, _scope, _provider, _integration_provider),
    do: {:error, :not_connected}

  defp to_credential({:error, :reauthorize_required}, _scope, _provider, _integration_provider),
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
     }}
  end

  defp oauth_entry({:error, reason}, _token), do: {:error, reason}

  # Pi stores the expiry as epoch milliseconds — `Date.now() + expires_in * 1000`
  # in its own refresh path — so handing it seconds would read as 1970 and make
  # every token permanently expired.
  defp expires_ms(%DateTime{} = expires_at), do: DateTime.to_unix(expires_at, :millisecond)
  defp expires_ms(nil), do: 0
end
