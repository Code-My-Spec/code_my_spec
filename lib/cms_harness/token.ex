defmodule CmsHarness.Token do
  @moduledoc """
  The access token the harness presents to the server, and where it comes from.

  The harness cannot run an authorization-code flow (no browser, no person, no
  Repo to keep a refresh in). So a deploy key is traded for a short-lived token
  at `POST /api/sprite/token` (`CodeMySpecWeb.SpriteTokenController`), which
  `require_oauth_token` accepts like any other client's. The key stays narrow
  (`Plugs.DeployKeyOrOAuth` mounts only on question routes), a leak expires,
  and one token can be revoked without stopping every harness on the project.

  The key comes from `CmsHarness.Credentials`; the token lives only in this
  process, keyed by working copy, and a restart re-exchanges. A signed-in
  user's token is handed back untouched, never exchanged.

  Not `CodeMySpec.AppTokens`, which serves a customer app's refresh secret.
  """

  use GenServer

  require Logger

  alias CmsHarness.Config
  alias CmsHarness.Credentials

  # Re-exchange this far ahead of expiry: a token expiring in flight is an
  # unexplained 401.
  @refresh_margin_seconds 300

  # The lifetime is the server's: `expires_in` is read off the response.
  @exchange_timeout 30_000

  @type refusal :: :no_credential | {:refused, integer()} | {:unreachable, term()}

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  A token good to present as `Authorization: Bearer`.

  Exchanges if it has to, serialised so a cold start's simultaneous callers
  share one exchange.
  """
  @spec access_token(String.t() | nil) :: {:ok, String.t()} | {:error, refusal()}
  def access_token(root \\ nil) do
    case credential(root) do
      {:ok, token, :user_token} -> {:ok, token}
      {:ok, key, _source} -> call_for_token(root, key)
      {:error, :no_credential} -> {:error, :no_credential}
    end
  end

  @doc """
  The same exchange, for a caller that already holds the key.

  For onboarding a checkout that has no recorded key yet, which
  `access_token/1`'s lookup (by root or served copy) cannot find.
  """
  @spec access_token_for_key(String.t()) :: {:ok, String.t()} | {:error, refusal()}
  def access_token_for_key(key) when is_binary(key) and key != "",
    do: call_for_token(nil, key)

  # A working copy's credential, or any (see `Credentials.any/0`).
  defp credential(nil), do: Credentials.any()
  defp credential(root), do: Credentials.for_working_copy(root)

  @doc """
  Throw away the cached token, so the next call exchanges again.

  For a 401 despite a fresh-looking token (revoked, or a redeployed server).
  """
  @spec invalidate() :: :ok
  def invalidate do
    if Process.whereis(__MODULE__), do: GenServer.cast(__MODULE__, :invalidate), else: :ok
  end

  # Without the process (a script, a test without the tree), exchange inline.
  defp call_for_token(root, key) do
    if Process.whereis(__MODULE__) do
      GenServer.call(__MODULE__, {:access_token, root, key}, @exchange_timeout + call_grace_ms())
    else
      case exchange(key) do
        {:ok, token, _expires_at} -> {:ok, token}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  # --- server ---

  # Keyed by working copy: a key reaches one project, and a daemon serves
  # several. `nil` (the copy-less lookup) caches too.
  @impl true
  def init(_opts), do: {:ok, %{}}

  @impl true
  def handle_call({:access_token, root, key}, _from, state) do
    if fresh?(Map.get(state, root)) do
      {:reply, {:ok, state[root].token}, state}
    else
      case exchange(key) do
        {:ok, token, expires_at} ->
          {:reply, {:ok, token}, Map.put(state, root, %{token: token, expires_at: expires_at})}

        {:error, reason} ->
          # Drop this copy's stale token even on failure.
          {:reply, {:error, reason}, Map.delete(state, root)}
      end
    end
  end

  @impl true
  def handle_cast(:invalidate, _state), do: {:noreply, %{}}

  defp fresh?(%{token: token, expires_at: expires_at})
       when is_binary(token) and is_integer(expires_at) do
    System.system_time(:second) + @refresh_margin_seconds < expires_at
  end

  defp fresh?(_), do: false

  # A blank key is a wiring bug (`Credentials` never returns one).
  defp usable(key) when is_binary(key) and key != "", do: {:ok, key}
  defp usable(_key), do: {:error, :no_credential}

  defp exchange(key) do
    with {:ok, key} <- usable(key) do
      url = Config.server_url() |> String.trim_trailing("/") |> Kernel.<>("/api/sprite/token")

      request =
        Req.new(
          method: :post,
          url: url,
          headers: [{"authorization", "Bearer " <> key}],
          # No retry: a bad key stays bad; an unreachable server is reported.
          retry: false,
          receive_timeout: @exchange_timeout
        )

      case Req.request(request) do
        {:ok, %{status: 200, body: %{"access_token" => token, "expires_in" => expires_in}}} ->
          Logger.info("[CmsHarness] exchanged the deploy key for a #{expires_in}s token")
          {:ok, token, System.system_time(:second) + expires_in}

        {:ok, %{status: 200}} ->
          Logger.error("[CmsHarness] token exchange returned 200 with no access_token")
          {:error, {:refused, 200}}

        {:ok, %{status: status}} ->
          Logger.error("[CmsHarness] token exchange refused: #{status}")
          {:error, {:refused, status}}

        {:error, reason} ->
          Logger.error("[CmsHarness] token exchange unreachable: #{inspect(reason)}")
          {:error, {:unreachable, reason}}
      end
    end
  end

  # A margin past the exchange timeout; configurable for tests.
  defp call_grace_ms, do: Application.get_env(:code_my_spec, :call_grace_ms, 5_000)
end
