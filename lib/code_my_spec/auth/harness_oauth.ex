defmodule CodeMySpec.Auth.HarnessOAuth do
  @moduledoc """
  The harness's own OAuth client and persisted credentials, isolated by server.
  Callers schedule device polling using the returned interval and deadline.
  No user database or deploy key is a credential source here.
  """

  @grant_type "urn:ietf:params:oauth:grant-type:device_code"

  @doc "The server used for harness authorization and account connections."
  @spec server_url() :: String.t()
  def server_url do
    Application.get_env(:code_my_spec, :harness_server_url_override) ||
      System.get_env("CMS_SERVER_URL") ||
      Application.get_env(:code_my_spec, :harness_server_url) ||
      Application.get_env(:code_my_spec, :base_url) ||
      Application.get_env(:code_my_spec, :harness_default_server_url, "http://localhost:4000")
  end

  def begin_authorization(server, device_id, opts \\ []) do
    locked(server, opts, fn path ->
      with {:ok, stored} <- read(path),
           {:ok, client} <- client(server, stored, path, opts),
           {:ok, body} <-
             request(
               server,
               "/oauth/device/code",
               [form: [client_id: client["client_id"], device_id: device_id]],
               opts
             ) do
        grant(body)
      end
    end)
  end

  def poll(server, grant, opts \\ []) do
    if System.monotonic_time(:second) >= grant.deadline do
      {:error, :expired_token}
    else
      locked(server, opts, fn path ->
        with {:ok, client} <- read(path),
             {:ok, body} <-
               request(
                 server,
                 "/oauth/token",
                 [
                   form:
                     credentials(client) ++
                       [grant_type: @grant_type, device_code: grant.device_code]
                 ],
                 opts
               ) do
          save_token(path, client, body)
        end
      end)
    end
  end

  def access_token(server, opts \\ []) do
    locked(server, opts, fn path ->
      with {:ok, stored} <- read(path) do
        token(server, path, stored, opts)
      end
    end)
  end

  defp token(_server, _path, %{"authorization_required" => true}, _opts),
    do: {:error, :authorization_required}

  defp token(server, path, %{"access_token" => token, "expires_at" => expires} = stored, opts)
       when is_binary(token) and token != "" and is_integer(expires) do
    refresh_before_seconds = Keyword.get(opts, :refresh_before_seconds, 300)

    if expires > System.system_time(:second) + refresh_before_seconds do
      {:ok, token}
    else
      refresh(server, path, stored, opts)
    end
  end

  defp token(_server, _path, _stored, _opts), do: {:error, :no_credential}

  defp refresh(server, path, %{"refresh_token" => refresh} = stored, opts)
       when is_binary(refresh) and refresh != "" do
    case request(
           server,
           "/oauth/token",
           [form: credentials(stored) ++ [grant_type: "refresh_token", refresh_token: refresh]],
           opts
         ) do
      {:ok, body} ->
        save_token(path, stored, body)

      {:error, reason} when reason in [:invalid_grant, :invalid_client, :invalid_request] ->
        invalidated =
          stored
          |> Map.drop(["access_token", "refresh_token", "expires_at"])
          |> Map.put("authorization_required", true)

        with :ok <- persist(path, invalidated) do
          {:error, :authorization_required}
        end

      error ->
        error
    end
  end

  defp refresh(_server, _path, _stored, _opts), do: {:error, :authorization_required}

  defp client(_server, %{"client_id" => id, "client_secret" => secret} = stored, _path, _opts)
       when is_binary(id) and id != "" and is_binary(secret) and secret != "",
       do: {:ok, stored}

  defp client(server, _stored, path, opts) do
    with {:ok, %{"client_id" => id, "client_secret" => secret}} <-
           request(
             server,
             "/oauth/register",
             [
               json: %{
                 client_name: "CodeMySpec Harness",
                 redirect_uris: [],
                 grant_types: [@grant_type, "refresh_token"]
               }
             ],
             opts
           ),
         true <- is_binary(id) and id != "" and is_binary(secret) and secret != "",
         stored = %{"client_id" => id, "client_secret" => secret},
         :ok <- persist(path, stored) do
      {:ok, stored}
    else
      {:error, _} = error -> error
      _ -> {:error, :invalid_response}
    end
  end

  defp grant(
         %{
           "device_code" => code,
           "user_code" => user_code,
           "verification_uri" => uri,
           "expires_in" => expires
         } = body
       )
       when is_binary(code) and is_binary(user_code) and is_binary(uri) and
              is_integer(expires) and expires > 0 do
    interval = Map.get(body, "interval", 5)

    if is_integer(interval) and interval > 0 do
      {:ok,
       %{
         device_code: code,
         user_code: user_code,
         verification_uri: uri,
         interval: interval,
         deadline: System.monotonic_time(:second) + expires
       }}
    else
      {:error, :invalid_response}
    end
  end

  defp grant(_), do: {:error, :invalid_response}

  defp save_token(path, stored, %{
         "access_token" => token,
         "refresh_token" => refresh,
         "expires_in" => expires
       })
       when is_binary(token) and token != "" and is_binary(refresh) and refresh != "" and
              is_integer(expires) and expires > 0 do
    data =
      Map.merge(Map.delete(stored, "authorization_required"), %{
        "access_token" => token,
        "refresh_token" => refresh,
        "expires_at" => System.system_time(:second) + expires
      })

    with :ok <- persist(path, data), do: {:ok, token}
  end

  defp save_token(_path, _stored, _body), do: {:error, :invalid_response}

  defp credentials(stored),
    do: [client_id: stored["client_id"], client_secret: stored["client_secret"]]

  defp request(server, route, body, opts) do
    options =
      [
        url: String.trim_trailing(server, "/") <> route,
        retry: false,
        redirect: false,
        receive_timeout: 30_000
      ] ++ body ++ Keyword.take(opts, [:plug])

    case Req.post(options) do
      {:ok, %{status: status, body: body}} when status in [200, 201] and is_map(body) ->
        {:ok, body}

      {:ok, %{body: %{"error" => error}}} ->
        oauth_error(error)

      {:ok, %{status: status}} ->
        {:error, {:http_status, status}}

      {:error, _reason} ->
        {:error, :unreachable}
    end
  end

  defp oauth_error("authorization_pending"), do: {:error, :authorization_pending}
  defp oauth_error("slow_down"), do: {:error, :slow_down}
  defp oauth_error("access_denied"), do: {:error, :access_denied}
  defp oauth_error("expired_token"), do: {:error, :expired_token}
  defp oauth_error("invalid_grant"), do: {:error, :invalid_grant}
  defp oauth_error("invalid_client"), do: {:error, :invalid_client}
  defp oauth_error("invalid_request"), do: {:error, :invalid_request}
  defp oauth_error(_), do: {:error, :authorization_failed}

  defp locked(server, opts, fun) do
    dir = Keyword.get_lazy(opts, :state_dir, &CodeMySpec.Paths.local_state_dir/0)
    hash = :crypto.hash(:sha256, String.trim_trailing(server, "/")) |> Base.encode16(case: :lower)
    path = Path.join(dir, "harness_oauth_#{hash}.json")
    :global.trans({{__MODULE__, Path.expand(path)}, self()}, fn -> fun.(path) end, [node()])
  end

  defp read(path) do
    case File.read(path) do
      {:ok, content} ->
        case Jason.decode(content) do
          {:ok, data} when is_map(data) -> {:ok, data}
          _ -> {:error, :invalid_credentials_file}
        end

      {:error, :enoent} ->
        {:ok, %{}}

      {:error, reason} ->
        {:error, {:credential_storage, reason}}
    end
  end

  defp persist(path, data) do
    temporary = path <> "." <> Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)

    result =
      with :ok <- File.mkdir_p(Path.dirname(path)),
           {:ok, file} <- File.open(temporary, [:write, :exclusive, :binary]) do
        try do
          with :ok <- File.chmod(temporary, 0o600),
               :ok <- IO.binwrite(file, Jason.encode!(data)),
               :ok <- :file.sync(file),
               :ok <- File.close(file) do
            File.rename(temporary, path)
          end
        after
          File.close(file)
          File.rm(temporary)
        end
      end

    case result do
      :ok -> :ok
      {:error, reason} -> {:error, {:credential_storage, reason}}
    end
  end
end
