defmodule CmsHarness.Token do
  @moduledoc """
  The access token the harness presents to the server, and where it comes from.

  ## Why a secret and an exchange rather than OAuth here

  The harness cannot run an authorization-code flow. There is no browser on a
  sprite, no person sitting at a container, and — the part that decides it — no
  database to keep the result in. `CodeMySpec.Auth.OAuthClient` refreshes tokens
  by reading `ClientUser` rows through the Repo, and a harness with a Repo is
  not the light harness.

  So the durable credential is a project deploy key, and this trades it for a
  short-lived token at `POST /api/sprite/token`. That endpoint already exists
  and was built for exactly this shape — see `CodeMySpecWeb.SpriteTokenController`,
  whose whole argument is that exchanging keeps the deploy key narrow while
  putting the holder on the same credential every other client uses, so
  `require_oauth_token` needs no special case. `/mcp/harness` sits behind that
  plug, which is why this is the piece that makes MCP work from a sprite.

  What the exchange buys over presenting the deploy key directly:

    * **The deploy key stays narrow.** `Plugs.DeployKeyOrOAuth` mounts on the
      question routes only, deliberately: a key that can interrupt its owner
      should not thereby inherit everything that owner can do. Widening it
      across the tool surface would undo that.
    * **A leak expires.** A deploy key is good until someone rotates it.
    * **Revocation fits the unit of work.** Revoking a deploy key stops every
      harness on that project. Revoking one token stops one.

  ## Nothing is written to disk

  The deploy key arrives in the environment — `CMS_DEPLOY_KEY`, from SOPS on a
  server, from the project page on a laptop — and the token it buys lives in
  this process and nowhere else. A restart re-exchanges. That is the whole
  store, and it is why the "file-backed credential store" this was going to
  need turned out not to exist: there is nothing worth persisting.

  ## `CMS_TOKEN` still wins

  Someone signed in on this machine already holds a user token, and it works
  against every one of these surfaces. When it is set, this hands it back
  untouched and never exchanges. The exchange is for the case with no user.

  ## This is not `CodeMySpec.AppTokens`

  Easy to conflate, and they are different mechanisms for different holders.
  `AppTokens` trades a *customer app's* refresh secret for a project-scoped
  `Phoenix.Token`, so a deployed app can call into CodeMySpec. This trades a
  *harness's* deploy key for a real OAuth access token, so the harness can call
  the tool surface as the project's owner.
  """

  use GenServer

  require Logger

  alias CmsHarness.Config
  alias CmsHarness.Credentials

  # Re-exchange this far ahead of expiry. A token that expires between the
  # check and the request arrives at the server as a 401 the caller cannot
  # explain, and the exchange is cheap.
  @refresh_margin_seconds 300

  # The server's token currently lasts 12 hours because nothing refreshed it —
  # `SpriteTokenController` says so in as many words, and that this is only
  # safe to shorten "once something on the sprite refreshes it". This is that
  # something. The lifetime is still the server's to choose; this reads
  # `expires_in` off the response rather than assuming it.
  @exchange_timeout 30_000

  @type refusal :: :no_credential | {:refused, integer()} | {:unreachable, term()}

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  A token good to present as `Authorization: Bearer`.

  Exchanges if it has to, and serialises doing so — several hooks and an MCP
  call can arrive at once on a cold start, and N simultaneous exchanges for one
  deploy key is N-1 tokens nobody uses.
  """
  @spec access_token(String.t() | nil) :: {:ok, String.t()} | {:error, refusal()}
  def access_token(root \\ nil) do
    case credential(root) do
      {:ok, token, :user_token} -> {:ok, token}
      {:ok, key, _source} -> call_for_token(root, key)
      {:error, :no_credential} -> {:error, :no_credential}
    end
  end

  # A working copy when the caller has one, any credential when it does not.
  # `WorkingCopies.ask_server/1` asks the server where a harness is; the answer
  # does not depend on who asks, and demanding a root there would make the
  # lookup impossible for the case it exists to resolve — an id this daemon
  # cannot yet place on disk.
  defp credential(nil), do: Credentials.any()
  defp credential(root), do: Credentials.for_working_copy(root)

  @doc """
  Throw away the cached token, so the next call exchanges again.

  For a 401 that arrives despite the token looking fresh — a revoked token, or
  a server that was redeployed with a different secret. Re-exchanging costs one
  request; continuing to present a token the server has rejected costs every
  request.
  """
  @spec invalidate() :: :ok
  def invalidate do
    if Process.whereis(__MODULE__), do: GenServer.cast(__MODULE__, :invalidate), else: :ok
  end

  # Without the process — a `mix run`, a test that did not start the tree — do
  # the exchange inline rather than failing. Losing the cache is a slower path,
  # not a broken one, and a credential module that only works under a
  # supervisor is a trap for exactly the scripts most likely to need it.
  defp call_for_token(root, key) do
    if Process.whereis(__MODULE__) do
      GenServer.call(__MODULE__, {:access_token, root, key}, @exchange_timeout + 5_000)
    else
      case exchange(key) do
        {:ok, token, _expires_at} -> {:ok, token}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  # --- server ---

  # Keyed by working copy. One cached token was right while a daemon held one
  # deploy key; a key reaches exactly one project, so a daemon serving several
  # holds several, and caching them in one slot would hand whichever was
  # exchanged last to whoever asked next.
  #
  # `nil` is a key like any other — the copy-less lookup — so it caches too.
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
          # The old token is dropped even on a failed exchange, and only this
          # copy's. Keeping one past its window means presenting a credential
          # known to be stale, and the refusal that comes back says nothing
          # about why.
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

  # The same `{:error, :no_credential}` `Config.deploy_key/0` used to answer, so
  # every caller's error handling is unchanged. Reached when a credential was
  # resolved and turns out to be unusable, which is a wiring bug rather than a
  # state — `Credentials` does not return blanks.
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
          # An exchange that fails is not usefully retried by us: a bad key
          # stays bad, and an unreachable server is something the caller has to
          # be told about rather than wait through.
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
end
