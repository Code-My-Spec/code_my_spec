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
      case build(scope, provider, integration_provider) do
        {:error, :not_connected} -> platform_credential(provider)
        result -> result
      end
    end
  end

  @doc """
  Ours, for a visitor who has connected nothing yet.

  Story 875: intake ends with the visitor talking to their project's agent, and
  someone who signed up ninety seconds ago has no provider. Making them connect
  one there puts an OAuth detour in the exact stretch the flow exists to make
  seamless, at the moment they have least invested.

  So the first conversation runs on our credential.

  ## Off unless configured, deliberately

  This spends real money on people who may never come back — the interview runs
  during the boot precisely because this funnel leaks.

  `Agents.turn_allowance/2` now bounds it: ten turns per visitor, configurable
  as `:platform_turn_cap`, enforced at `dispatch_message/3` and reported to the
  visitor before they reach it. That is one of the three bounds this doc used to
  say were missing; there is still no token budget and no expiry, so ten turns
  of an expensive model is the worst case a deployment is agreeing to.

  Still off by default. A cap makes the spend bounded, not free, and a default
  that started spending on a version bump would be the wrong way round for a
  commercial decision — the number is small enough to switch on deliberately and
  large enough to matter multiplied by a funnel.

  Only ever reached when the visitor's own integration is missing. Someone who
  has connected their own provider uses it — this never silently pays for a
  customer who is already paying for themselves.
  """
  @spec platform_credential(String.t()) :: {:ok, t()} | {:error, :not_connected}
  def platform_credential(_provider) do
    # Trimmed, not just non-nil. A blank value is what an unset environment
    # variable looks like once it has been through config — `""` or a few
    # spaces — and it is truthy, so a bare presence check hands out a
    # credential made of whitespace and the agent fails on its first call
    # somewhere far from here.
    case config()[:platform_api_key] |> to_string() |> String.trim() do
      key when key != "" ->
        # The same two-key shape the connected path builds. An extra field here
        # would be one this module's own moduledoc says Pi does not read.
        {:ok, %{"type" => "api_key", "key" => key}}

      _ ->
        {:error, :not_connected}
    end
  end

  @doc """
  Whose credential an agent on this provider would run on.

  `:user` is theirs, `:platform` is ours, `:none` is nobody's — the agent cannot
  start at all.

  Asked separately from `fetch/2` because the two callers want different things.
  Starting an agent does not care whose credential it got, and folding the
  answer into the return value would make every caller handle a distinction
  almost none of them have an opinion about. What *does* care is the turn cap:
  it exists because we are paying, so it has to apply to exactly the agents we
  are paying for and to no others.

  Derived rather than stored, and that is deliberate. A visitor who connects
  their own provider later is paying for themselves from that moment, and their
  cap should lift without anything having to notice and update a row. A stored
  flag would say "started on ours" forever, which is a fact about the past
  rather than about who is spending now.
  """
  @spec source(Scope.t(), String.t()) :: :user | :platform | :none
  def source(%Scope{} = scope, provider) when is_binary(provider) do
    with {:ok, integration_provider} <- Providers.integration_provider(provider) do
      case build(scope, provider, integration_provider) do
        {:ok, _credential} ->
          :user

        # A credential that needs reconnecting is still theirs. Treating it as
        # ours would put a cap on someone who is paying and has a token to
        # refresh, and `fetch/2` does not fall back for this case either.
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
    else
      _ -> :none
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

  # A refresh the provider refused is a credential that needs reconnecting,
  # whatever shape the refusal arrived in. Passing the transport error through
  # would report an `Assent.InvalidResponseError` at somebody who connected a
  # subscription and wants to know what to do about it — and `invalid_grant` is
  # exactly what a superseded refresh token gets, which is the case this has to
  # name correctly rather than dump.
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
     |> put_account_id(token)}
  end

  defp oauth_entry({:error, reason}, _token), do: {:error, reason}

  # OpenAI's account id, which Pi sends as the `chatgpt-account-id` header on
  # every model call (`openai-codex-responses.js`). An `auth.json` without it
  # authenticates and then fails on the first request — the quiet failure this
  # story's rules exist to keep out.
  #
  # Read from the access token rather than stored beside it, the way Pi reads it
  # (`getAccountId/1` decodes the JWT and takes `chatgpt_account_id`). Deriving
  # it means a refreshed token brings its own, instead of us carrying a copy that
  # can go stale against the grant it describes.
  #
  # A token that carries no such claim is left alone: providers other than
  # OpenAI have no account id, and inventing an empty one would send an empty
  # header rather than none.
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

  # Pi stores the expiry as epoch milliseconds — `Date.now() + expires_in * 1000`
  # in its own refresh path — so handing it seconds would read as 1970 and make
  # every token permanently expired.
  defp expires_ms(%DateTime{} = expires_at), do: DateTime.to_unix(expires_at, :millisecond)
  defp expires_ms(nil), do: 0
end
