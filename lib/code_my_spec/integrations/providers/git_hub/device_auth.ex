defmodule CodeMySpec.Integrations.Providers.GitHub.DeviceAuth do
  @moduledoc """
  GitHub's device flow, for the desktop app (bb8bc042).

  The desktop keeps no client secret, and GitHub's web flow needs one at the
  token exchange. The device flow needs only the client id: the human types a
  short code at github.com/login/device and we poll until GitHub answers.

      POST https://github.com/login/device/code        {client_id, scope}
        -> {device_code, user_code, verification_uri, interval}
      POST https://github.com/login/oauth/access_token  {client_id, device_code, grant_type}
        -> {access_token, scope}   or  {error: authorization_pending | slow_down | ...}

  "Enable Device Flow" has to be ticked on the OAuth app; without it the first
  call answers `device_flow_disabled`.
  """

  alias CodeMySpec.Integrations.Providers.GitHub

  @device_grant "urn:ietf:params:oauth:grant-type:device_code"

  @type device :: %{
          provider: :github,
          device_code: String.t(),
          user_code: String.t(),
          interval_seconds: pos_integer(),
          verification_uri: String.t()
        }

  @doc "Ask GitHub for a code the human can type."
  @spec request_device_code() :: {:ok, device()} | {:error, term()}
  def request_device_code do
    scope = GitHub.config()[:authorization_params][:scope]

    case post("https://github.com/login/device/code", client_id: client_id(), scope: scope) do
      {:ok, %{"device_code" => code, "user_code" => user_code} = body} ->
        {:ok,
         %{
           provider: :github,
           device_code: code,
           user_code: user_code,
           interval_seconds: body["interval"] || 5,
           verification_uri: body["verification_uri"] || "https://github.com/login/device"
         }}

      {:ok, %{"error" => error}} ->
        {:error, error}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Ask whether the human has finished. `{:error, :pending}` is the ordinary
  answer; `slow_down` comes back as `{:error, {:slow_down, seconds}}` with the
  interval GitHub now wants.
  """
  @spec poll(device()) ::
          {:ok, %{token: map(), user: map()}}
          | {:error, :pending | {:slow_down, pos_integer()} | term()}
  def poll(%{device_code: code} = device) do
    form = [client_id: client_id(), device_code: code, grant_type: @device_grant]

    case post("https://github.com/login/oauth/access_token", form) do
      {:ok, %{"access_token" => token} = response} ->
        with_user(response, token)

      {:ok, %{"error" => "authorization_pending"}} ->
        {:error, :pending}

      {:ok, %{"error" => "slow_down"} = body} ->
        {:error, {:slow_down, body["interval"] || device.interval_seconds + 5}}

      {:ok, %{"error" => error}} ->
        {:error, error}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # GitHub.normalize_user/1 takes Assent's normalized fields; this is the same
  # mapping Assent.Strategy.Github applies to GET /user.
  defp with_user(response, token) do
    case Req.get("https://api.github.com/user", [auth: {:bearer, token}] ++ req_options()) do
      {:ok, %Req.Response{status: 200, body: user}} ->
        {:ok,
         %{
           token: response,
           user: %{
             "sub" => user["id"],
             "email" => user["email"],
             "name" => user["name"],
             "preferred_username" => user["login"],
             "picture" => user["avatar_url"]
           }
         }}

      {:ok, %Req.Response{status: status}} ->
        {:error, {:user_fetch, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp post(url, form) do
    case Req.post(url, [form: form, headers: [accept: "application/json"]] ++ req_options()) do
      {:ok, %Req.Response{status: 200, body: body}} when is_map(body) -> {:ok, body}
      {:ok, %Req.Response{status: status}} -> {:error, {:unexpected, status}}
      {:error, reason} -> {:error, {:unreachable, reason}}
    end
  end

  defp client_id do
    Application.get_env(:code_my_spec, :desktop_oauth_clients, [])[:github_client_id] ||
      Application.fetch_env!(:code_my_spec, :github_client_id)
  end

  defp req_options, do: Application.get_env(:code_my_spec, __MODULE__, [])
end
