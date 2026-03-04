defmodule CodeMySpec.Auth.OAuthClient do
  @moduledoc """
  OAuth2 client for authentication.

  Provides core OAuth functionality: token management, client registration,
  PKCE helpers, and user info fetching. CLI-specific flows (interactive browser
  auth) are in `CodeMySpecCli.Auth.OAuthClient`.
  """

  require Logger

  import Ecto.Query

  alias CodeMySpec.Auth.Strategy
  alias CodeMySpec.ClientUsers.ClientUser
  alias CodeMySpec.Repo

  @client_config_file ".codemyspec_client"

  # --- Token Management ---

  @doc """
  Get a valid access token, refreshing if necessary.

  Queries the database directly for the active client user (most recently
  updated user with a valid token).
  """
  def get_token do
    case get_active_client_user() do
      {:ok, user} ->
        if token_expired?(user) do
          refresh_token_for_user(user)
        else
          {:ok, user.oauth_token}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Check if user is authenticated.
  """
  def authenticated? do
    case get_token() do
      {:ok, _token} -> true
      {:error, _} -> false
    end
  end

  @doc """
  Clear stored credentials from database for the active user.
  """
  def logout do
    case get_active_client_user() do
      {:ok, user} ->
        user
        |> ClientUser.changeset(%{
          oauth_token: nil,
          oauth_refresh_token: nil,
          oauth_expires_at: nil
        })
        |> Repo.update()

        :ok

      {:error, _} ->
        :ok
    end
  end

  @doc """
  Check if a user's token is expired.
  Returns true if token is nil or expires in less than 5 minutes.
  """
  def token_expired?(%ClientUser{oauth_expires_at: nil}), do: true

  def token_expired?(%ClientUser{oauth_expires_at: expires_at}) do
    DateTime.compare(DateTime.utc_now(), DateTime.add(expires_at, -300, :second)) == :gt
  end

  @doc """
  Extract expires_in (seconds) from an OAuth2.AccessToken struct.
  """
  def extract_expires_in(%OAuth2.AccessToken{} = token) do
    token.other_params["expires_in"] ||
      calculate_expires_in_from_timestamp(token.expires_at) ||
      7200
  end

  # --- Client Registration ---

  @doc """
  Get or register an OAuth client for the given server URL.

  Returns `{:ok, client_id, client_secret}`.
  """
  def get_or_register_client(server_base_url, redirect_uri \\ nil) do
    config_path = Path.join(System.user_home!(), @client_config_file)

    case File.read(config_path) do
      {:ok, content} ->
        data = Jason.decode!(content)

        if data["server_url"] == server_base_url do
          {:ok, data["client_id"], data["client_secret"]}
        else
          register_new_client(config_path, server_base_url, redirect_uri)
        end

      {:error, _} ->
        register_new_client(config_path, server_base_url, redirect_uri)
    end
  end

  # --- PKCE & State Helpers ---

  @doc """
  Generate a PKCE code verifier and challenge pair.

  Returns `{code_verifier, code_challenge}`.
  """
  def generate_pkce_pair do
    code_verifier = :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)

    code_challenge =
      :crypto.hash(:sha256, code_verifier)
      |> Base.url_encode64(padding: false)

    {code_verifier, code_challenge}
  end

  @doc """
  Generate a random state parameter for OAuth.
  """
  def generate_state do
    :crypto.strong_rand_bytes(16) |> Base.url_encode64(padding: false)
  end

  # --- User Info & Persistence ---

  @doc """
  Fetch user info from the server using an access token.

  Returns `{:ok, %{id: id, email: email}}` or `{:error, reason}`.
  """
  def fetch_user_info(server_base_url, access_token) do
    url = "#{server_base_url}/api/me"
    req_opts = build_req_opts(server_base_url)
    headers = [{"authorization", "Bearer #{access_token}"}]

    case Req.get(url, Keyword.merge([headers: headers], req_opts)) do
      {:ok, %{status: 200, body: %{"id" => id, "email" => email}}} ->
        {:ok, %{id: id, email: email}}

      {:ok, %{status: status, body: body}} ->
        {:error, "Failed to fetch user info (HTTP #{status}): #{inspect(body)}"}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Save or update a client user in the database with OAuth token data.

  `token_data` should be a map with keys: "access_token", "refresh_token", "expires_in".
  """
  def save_client_user(user_id, email, token_data) do
    attrs = %{
      id: user_id,
      email: email,
      oauth_token: token_data["access_token"],
      oauth_refresh_token: token_data["refresh_token"],
      oauth_expires_at: DateTime.add(DateTime.utc_now(), token_data["expires_in"], :second)
    }

    case Repo.get(ClientUser, user_id) do
      nil ->
        %ClientUser{}
        |> ClientUser.changeset(attrs)
        |> Repo.insert()

      existing_user ->
        existing_user
        |> ClientUser.changeset(attrs)
        |> Repo.update()
    end
  end

  # --- Server URL ---

  @doc """
  Get the server URL for OAuth flows.
  """
  def get_server_url do
    Application.get_env(:code_my_spec, :base_url, "https://dev.codemyspec.com")
  end

  # --- Token Exchange (for callback flows) ---

  @doc """
  Exchange an authorization code for tokens.

  Used by both CLI and bootstrap callback flows.
  Returns `{:ok, token_data}` or `{:error, reason}`.
  """
  def exchange_code_for_token(code, code_verifier, client_id, client_secret, redirect_uri) do
    server_base_url = get_server_url()

    client =
      OAuth2.Client.new(
        strategy: Strategy,
        client_id: client_id,
        client_secret: client_secret,
        site: server_base_url,
        token_url: "#{server_base_url}/oauth/token",
        redirect_uri: redirect_uri,
        request_opts: build_httpc_opts(server_base_url)
      )

    params = [
      code: code,
      code_verifier: code_verifier,
      client_id: client_id,
      client_secret: client_secret,
      grant_type: "authorization_code",
      redirect_uri: redirect_uri
    ]

    case OAuth2.Client.get_token(client, params) do
      {:ok, %OAuth2.Client{token: token}} ->
        {:ok, parsed} = Jason.decode(token.access_token)

        token_data = %{
          "access_token" => parsed["access_token"],
          "refresh_token" => parsed["refresh_token"],
          "expires_in" => parsed["expires_in"],
          "token_type" => parsed["token_type"] || "Bearer",
          "scope" => parsed["scope"]
        }

        {:ok, token_data}

      {:error, %OAuth2.Error{reason: reason}} ->
        {:error, "Token exchange failed: #{inspect(reason)}"}

      {:error, %OAuth2.Response{status_code: status, body: body}} ->
        {:error, "Token exchange failed (#{status}): #{inspect(body)}"}
    end
  end

  # --- Internal ---

  @doc false
  def get_active_client_user do
    query =
      from u in ClientUser,
        where: not is_nil(u.oauth_token),
        order_by: [desc: u.updated_at],
        limit: 1

    case Repo.one(query) do
      nil -> {:error, :not_authenticated}
      user -> {:ok, user}
    end
  end

  defp refresh_token_for_user(%{oauth_refresh_token: nil}), do: {:error, :needs_authentication}

  defp refresh_token_for_user(user) do
    server_base_url = get_server_url()
    {:ok, client_id, client_secret} = get_or_register_client(server_base_url)

    client =
      OAuth2.Client.new(
        strategy: Strategy,
        client_id: client_id,
        client_secret: client_secret,
        site: server_base_url,
        token_url: "#{server_base_url}/oauth/token",
        request_opts: build_httpc_opts(server_base_url)
      )

    params = [
      refresh_token: user.oauth_refresh_token,
      grant_type: "refresh_token",
      client_id: client_id,
      client_secret: client_secret
    ]

    client
    |> OAuth2.Client.get_token(params)
    |> handle_refresh_result(user)
  end

  defp handle_refresh_result({:ok, %OAuth2.Client{token: token}}, user) do
    {:ok, parsed} = Jason.decode(token.access_token)

    token_data = %{
      "access_token" => parsed["access_token"],
      "refresh_token" => parsed["refresh_token"] || user.oauth_refresh_token,
      "expires_in" => parsed["expires_in"]
    }

    case save_client_user(user.id, user.email, token_data) do
      {:ok, _} -> {:ok, token_data["access_token"]}
      {:error, reason} ->
        Logger.error("Failed to save refreshed token: #{inspect(reason)}")
        {:error, :needs_authentication}
    end
  end

  defp handle_refresh_result({:error, %OAuth2.Error{reason: reason}}, _user) do
    Logger.error("Token refresh failed (OAuth2.Error): #{inspect(reason)}")
    {:error, :needs_authentication}
  end

  defp handle_refresh_result({:error, %OAuth2.Response{status_code: status, body: body}}, _user) do
    Logger.error("Token refresh failed (HTTP #{status}): #{inspect(body)}")
    {:error, :needs_authentication}
  end

  defp handle_refresh_result({:error, reason}, _user) do
    Logger.error("Token refresh failed: #{inspect(reason)}")
    {:error, :needs_authentication}
  end

  defp register_new_client(config_path, server_base_url, redirect_uri) do
    redirect_uris =
      if redirect_uri do
        [redirect_uri]
      else
        ["http://localhost:4002/api/bootstrap/auth/callback"]
      end

    registration_params = %{
      client_name: "CodeMySpec CLI",
      redirect_uris: redirect_uris
    }

    url = "#{server_base_url}/oauth/register"
    req_opts = build_req_opts(server_base_url)

    case Req.post(url, Keyword.merge([json: registration_params], req_opts)) do
      {:ok, %{status: 201, body: body}} ->
        client_id = body["client_id"]
        client_secret = body["client_secret"]

        File.write!(
          config_path,
          Jason.encode!(%{
            server_url: server_base_url,
            client_id: client_id,
            client_secret: client_secret
          })
        )

        File.chmod!(config_path, 0o600)

        {:ok, client_id, client_secret}

      {:ok, %{status: status, body: body}} when is_binary(body) ->
        if String.contains?(body, "<!DOCTYPE html>") do
          raise "Server is not reachable at #{server_base_url}. Is the Phoenix server running?"
        else
          raise "Client registration failed (HTTP #{status}): #{String.slice(body, 0, 200)}"
        end

      {:ok, response} ->
        raise "Client registration failed (HTTP #{response.status}): #{inspect(response.body)}"

      {:error, %Mint.TransportError{reason: :econnrefused}} ->
        raise "Cannot connect to server at #{server_base_url}. Is the Phoenix server running?"

      {:error, reason} ->
        raise "Failed to connect to server at #{server_base_url}: #{inspect(reason)}"
    end
  end

  defp calculate_expires_in_from_timestamp(nil), do: nil

  defp calculate_expires_in_from_timestamp(expires_at) when is_integer(expires_at) do
    max(0, expires_at - System.system_time(:second))
  end

  # Build Req options for HTTP requests
  defp build_req_opts(server_url) do
    if String.starts_with?(server_url, "https://localhost") do
      [connect_options: [transport_opts: [verify: :verify_none]]]
    else
      []
    end
  end

  # Build SSL options for OAuth2 library (Tesla with httpc adapter)
  defp build_httpc_opts(server_url) do
    if String.starts_with?(server_url, "https://localhost") do
      [ssl: [verify: :verify_none]]
    else
      []
    end
  end
end
