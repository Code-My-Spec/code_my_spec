defmodule CodeMySpec.Integrations.Providers.OpenAI.DeviceAuth do
  @moduledoc """
  Pi's ChatGPT login, reproduced — the device-code half.

  ## Why this half and not the browser half

  Pi offers both. The browser flow cannot be copied server-side, and not for
  want of trying: its `redirect_uri` is `http://localhost:1455/auth/callback`,
  a fixed value registered against Pi's client. A redirect URI is checked
  against the client's registration, so a callback of ours — hosted, on a
  container, anywhere but that port on that machine — is refused before a human
  ever sees a consent screen. Copying the browser flow means running a listener
  on port 1455 of the user's own machine, which the local app could do and a
  cloud host never can.

  The device flow needs no redirect of ours at all. OpenAI's own
  `/deviceauth/callback` absorbs it, the human types a short code on a page they
  already trust, and the credential lands wherever the polling happened. That is
  the one shape that works from a container, and the multi-tenant host is the
  case this story is ultimately for.

  ## The exchange, as Pi performs it

      POST /api/accounts/deviceauth/usercode  {client_id}
        -> {device_auth_id, user_code, interval}

      (human enters user_code at https://auth.openai.com/codex/device)

      POST /api/accounts/deviceauth/token     {device_auth_id, user_code}
        -> {authorization_code, code_verifier}      403/404 while pending

      POST /oauth/token  grant_type=authorization_code
        -> {access_token, refresh_token, expires_in}

  The verifier arriving *from* the server in step three is the part worth
  noticing: this is PKCE with the challenge minted at OpenAI's end rather than
  ours, which is why nothing here generates one.

  ## Client id

  Pi's, `app_EMoamEEZ73f0CkXaXp7hrann`, for the same reason
  `CodeMySpec.Integrations.Providers.OpenAI` uses it: the grant this mints is
  one Pi will spend, and a refresh token is bound to the client that issued it.
  `originator` is `pi` for the same reason — it is how OpenAI attributes the
  session, and claiming to be something else would be a lie told to the party
  granting the credential.
  """

  @auth_base "https://auth.openai.com"
  @client_id "app_EMoamEEZ73f0CkXaXp7hrann"
  @originator "pi"
  @verification_uri "#{@auth_base}/codex/device"
  @device_redirect_uri "#{@auth_base}/deviceauth/callback"

  @type device :: %{
          device_auth_id: String.t(),
          user_code: String.t(),
          interval_seconds: pos_integer(),
          verification_uri: String.t()
        }

  @doc """
  Ask OpenAI for a code the human can type.

  Returns what to show them and how often to poll.
  """
  @spec request_device_code() :: {:ok, device()} | {:error, term()}
  def request_device_code do
    [
      url: "#{@auth_base}/api/accounts/deviceauth/usercode",
      json: %{client_id: client_id(), originator: @originator}
    ]
    |> request()
    |> to_device()
  end

  @doc """
  Ask whether the human has finished yet.

  `{:error, :pending}` is the ordinary answer and not a failure — OpenAI
  answers 403 or 404 while it waits, which is indistinguishable from a
  transport problem unless it is named.
  """
  @spec poll(device()) ::
          {:ok, %{authorization_code: String.t(), code_verifier: String.t()}}
          | {:error, :pending | term()}
  def poll(%{device_auth_id: id, user_code: code}) do
    [
      url: "#{@auth_base}/api/accounts/deviceauth/token",
      json: %{device_auth_id: id, user_code: code}
    ]
    |> request()
    |> to_authorization()
  end

  @doc """
  Trade the authorization code for the tokens an agent runs on.

  The verifier is the one OpenAI handed back, not one we minted.
  """
  @spec exchange(%{authorization_code: String.t(), code_verifier: String.t()}) ::
          {:ok, map()} | {:error, term()}
  def exchange(%{authorization_code: code, code_verifier: verifier}) do
    [
      url: "#{@auth_base}/oauth/token",
      form: [
        grant_type: "authorization_code",
        code: code,
        code_verifier: verifier,
        client_id: client_id(),
        redirect_uri: @device_redirect_uri
      ]
    ]
    |> request()
    |> to_tokens()
  end

  @doc "Where to send the human."
  @spec verification_uri() :: String.t()
  def verification_uri, do: @verification_uri

  defp client_id, do: Application.get_env(:code_my_spec, :openai_client_id, @client_id)

  # One place the plug is applied, so a test pins this the way every other Req
  # client here is pinned rather than reaching the network.
  defp request(opts) do
    opts
    |> Keyword.merge(Application.get_env(:code_my_spec, __MODULE__, []))
    |> Req.post()
  end

  defp to_device({:ok, %Req.Response{status: 200, body: body}}) do
    with {:ok, id} <- fetch(body, "device_auth_id"),
         {:ok, code} <- fetch(body, "user_code") do
      {:ok,
       %{
         device_auth_id: id,
         user_code: code,
         interval_seconds: interval(body),
         verification_uri: @verification_uri
       }}
    end
  end

  defp to_device({:ok, %Req.Response{status: status, body: body}}),
    do: {:error, {:device_code_refused, status, body}}

  defp to_device({:error, reason}), do: {:error, reason}

  # 403 and 404 are "not yet", not "no". Pi treats them the same way, and a
  # poller that reads them as failure gives up on every login before the human
  # has finished reading the code.
  defp to_authorization({:ok, %Req.Response{status: status}}) when status in [403, 404],
    do: {:error, :pending}

  defp to_authorization({:ok, %Req.Response{status: 200, body: body}}) do
    with {:ok, code} <- fetch(body, "authorization_code"),
         {:ok, verifier} <- fetch(body, "code_verifier") do
      {:ok, %{authorization_code: code, code_verifier: verifier}}
    end
  end

  defp to_authorization({:ok, %Req.Response{body: body}}) do
    case pending?(body) do
      true -> {:error, :pending}
      false -> {:error, {:device_auth_failed, body}}
    end
  end

  defp to_authorization({:error, reason}), do: {:error, reason}

  defp to_tokens({:ok, %Req.Response{status: 200, body: body}}), do: {:ok, body}
  defp to_tokens({:ok, %Req.Response{status: status, body: body}}),
    do: {:error, {:token_exchange_failed, status, body}}

  defp to_tokens({:error, reason}), do: {:error, reason}

  defp pending?(%{"error" => %{"code" => "deviceauth_authorization_pending"}}), do: true
  defp pending?(%{"error" => "deviceauth_authorization_pending"}), do: true
  defp pending?(_body), do: false

  defp fetch(body, key) when is_map(body) do
    case Map.get(body, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, {:missing_field, key, body}}
    end
  end

  defp fetch(body, key), do: {:error, {:missing_field, key, body}}

  # OpenAI returns the interval as a number or a string depending on the path;
  # Pi coerces it too. Defaults low rather than high — polling too slowly makes
  # a login look hung to the person waiting on it.
  defp interval(%{"interval" => n}) when is_integer(n) and n > 0, do: n

  defp interval(%{"interval" => s}) when is_binary(s) do
    case Integer.parse(String.trim(s)) do
      {n, _} when n > 0 -> n
      _ -> 5
    end
  end

  defp interval(_body), do: 5
end
