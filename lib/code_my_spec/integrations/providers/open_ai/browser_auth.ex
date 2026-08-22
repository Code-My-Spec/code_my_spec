defmodule CodeMySpec.Integrations.Providers.OpenAI.BrowserAuth do
  @moduledoc """
  Pi's ChatGPT login, the way Pi actually does it.

  Pi does not use the device flow, and neither should we where we can avoid it.
  It opens a browser at `auth.openai.com/oauth/authorize` and catches the
  callback on a transient HTTP server it starts on port 1455 — the port its
  client registers as `http://localhost:1455/auth/callback`. That is one click
  and one consent screen, against a device code the human has to read off one
  screen and type into another.

  The reason to reach for device code was never Pi's flow being unavailable; it
  was picking the wrong host. A redirect to `localhost:1455` cannot be caught by
  a server running somewhere else, so the hosted app at `:4000` cannot do this.
  The local app runs on the same machine as the browser and the agent, which is
  the whole point of it, so it can do exactly what Pi does.

  `DeviceAuth` remains for the case that genuinely has no browser — a container,
  a box reached over ssh — and not as the ordinary path.

  ## The flow

      GET  /oauth/authorize?response_type=code&client_id=…&redirect_uri=http://localhost:1455/auth/callback
                           &scope=openid profile email offline_access
                           &code_challenge=…&code_challenge_method=S256&state=…
      <- browser redirects to localhost:1455/auth/callback?code=…&state=…
      POST /oauth/token    grant_type=authorization_code, code, code_verifier, client_id, redirect_uri

  PKCE is ours here, unlike the device flow where OpenAI mints the verifier and
  hands it back. `state` is checked on the way in — a callback carrying somebody
  else's state is a cross-site request, not a login.
  """

  require Logger

  alias CodeMySpec.Integrations.Providers.OpenAI.BrowserAuth.CallbackPlug

  @auth_base "https://auth.openai.com"
  @client_id "app_EMoamEEZ73f0CkXaXp7hrann"
  @originator "pi"
  @port 1455
  @redirect_uri "http://localhost:#{@port}/auth/callback"
  @scope "openid profile email offline_access"

  @type pending :: %{
          authorize_url: String.t(),
          state: String.t(),
          verifier: String.t(),
          listener: pid()
        }

  @doc """
  Start the listener and build the URL to send the browser to.

  The listener comes up first on purpose. Opening the browser and then binding
  the port races a fast human, and the failure is a callback answered by nothing
  — which looks to them like OpenAI being broken.
  """
  @spec begin() :: {:ok, pending()} | {:error, term()}
  def begin do
    verifier = random(64)
    state = random(32)

    with {:ok, listener} <- start_listener(state) do
      {:ok,
       %{
         authorize_url: authorize_url(verifier, state),
         state: state,
         verifier: verifier,
         listener: listener
       }}
    end
  end

  @doc """
  Wait for the browser to come back, then trade the code for tokens.

  Times out rather than waiting forever: a login nobody finished should release
  the port, or the next attempt fails to bind and reports something that has
  nothing to do with what went wrong.
  """
  @spec await(pending(), timeout()) :: {:ok, map()} | {:error, term()}
  def await(%{listener: listener, verifier: verifier}, timeout \\ 300_000) do
    receive do
      {:openai_oauth_code, code} ->
        stop_listener(listener)
        exchange(code, verifier)

      {:openai_oauth_error, reason} ->
        stop_listener(listener)
        {:error, reason}
    after
      timeout ->
        stop_listener(listener)
        {:error, :timeout}
    end
  end

  @doc "Give the port back without waiting, for a login the human abandoned."
  @spec cancel(pending()) :: :ok
  def cancel(%{listener: listener}), do: stop_listener(listener)

  @doc "Where the browser goes."
  @spec authorize_url(String.t(), String.t()) :: String.t()
  def authorize_url(verifier, state) do
    query =
      URI.encode_query(%{
        "response_type" => "code",
        "client_id" => client_id(),
        "redirect_uri" => @redirect_uri,
        "scope" => @scope,
        "code_challenge" => challenge(verifier),
        "code_challenge_method" => "S256",
        "state" => state,
        # Pi sends both. They are not decoration: without the simplified-flow
        # flag the consent screen is the full Codex one, and the organizations
        # claim is what puts `chatgpt_account_id` in the id token.
        "id_token_add_organizations" => "true",
        "codex_cli_simplified_flow" => "true",
        "originator" => @originator
      })

    "#{@auth_base}/oauth/authorize?#{query}"
  end

  @spec redirect_uri() :: String.t()
  def redirect_uri, do: @redirect_uri

  @spec port() :: pos_integer()
  def port, do: @port

  defp client_id, do: Application.get_env(:code_my_spec, :openai_client_id, @client_id)

  # `Bandit.start_link/1` links, so a failed bind takes the caller down instead
  # of returning. Trapping exits for the length of the attempt turns that into
  # an answer; the flag is put back either way, because leaving a caller trapping
  # exits changes how every later crash in it behaves.
  defp start_listener(state) do
    trapping? = Process.flag(:trap_exit, true)

    try do
      Bandit.start_link(
        plug: {CallbackPlug, %{state: state, reply_to: self()}},
        scheme: :http,
        port: @port,
        ip: {127, 0, 0, 1}
      )
      |> to_listener()
    catch
      :exit, _reason -> {:error, :port_in_use}
    after
      Process.flag(:trap_exit, trapping?)
    end
  end

  defp to_listener({:ok, pid}), do: {:ok, pid}

  # Pi itself may be mid-login on the same port. Saying so beats "address in
  # use", which reads as our bug rather than as somebody else holding it.
  defp to_listener({:error, {:shutdown, {:failed_to_start_child, _, :eaddrinuse}}}),
    do: {:error, :port_in_use}

  defp to_listener({:error, :eaddrinuse}), do: {:error, :port_in_use}
  defp to_listener({:error, reason}), do: {:error, reason}

  defp stop_listener(pid) when is_pid(pid) do
    if Process.alive?(pid) do
      # Unlinked first: stopping a linked supervisor from a process that is not
      # trapping exits takes the caller with it.
      Process.unlink(pid)
      Supervisor.stop(pid, :normal, 5_000)
    end

    :ok
  catch
    :exit, _reason -> :ok
  end

  defp stop_listener(_), do: :ok

  defp exchange(code, verifier) do
    [
      url: "#{@auth_base}/oauth/token",
      form: [
        grant_type: "authorization_code",
        code: code,
        code_verifier: verifier,
        client_id: client_id(),
        redirect_uri: @redirect_uri
      ]
    ]
    |> Keyword.merge(Application.get_env(:code_my_spec, __MODULE__, []))
    |> Req.post()
    |> to_tokens()
  end

  defp to_tokens({:ok, %Req.Response{status: 200, body: body}}), do: {:ok, body}

  defp to_tokens({:ok, %Req.Response{status: status, body: body}}),
    do: {:error, {:token_exchange_failed, status, body}}

  defp to_tokens({:error, reason}), do: {:error, reason}

  defp random(bytes), do: bytes |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)

  defp challenge(verifier),
    do: :sha256 |> :crypto.hash(verifier) |> Base.url_encode64(padding: false)
end
