defmodule CodeMySpecLocalWeb.BootstrapController do
  @moduledoc """
  OAuth flow endpoints for agent-driven authentication.

  These are the only bootstrap actions that need HTTP controllers — they
  require browser redirects for the OAuth PKCE flow. All other bootstrap
  actions (init, install, setup) are MCP tools.
  """
  use CodeMySpecLocalWeb, :controller

  require Logger

  alias CodeMySpec.Auth.AuthState
  alias CodeMySpec.Auth.OAuthClient

  def auth_status(conn, _params) do
    case OAuthClient.get_active_client_user() do
      {:ok, user} ->
        if OAuthClient.token_expired?(user) do
          json(conn, %{authenticated: false})
        else
          json(conn, %{authenticated: true, email: user.email})
        end

      {:error, _} ->
        json(conn, %{authenticated: false})
    end
  end

  def auth_start(conn, _params) do
    server_url = OAuthClient.get_server_url()
    redirect_uri = "#{CodeMySpecLocalWeb.Endpoint.url()}/api/bootstrap/auth/callback"

    case OAuthClient.get_or_register_client(server_url, redirect_uri) do
      {:ok, client_id, client_secret} ->
        {code_verifier, code_challenge} = OAuthClient.generate_pkce_pair()
        state = OAuthClient.generate_state()

        auth_url =
          "#{server_url}/oauth/authorize?" <>
            "client_id=#{client_id}" <>
            "&code_challenge=#{code_challenge}" <>
            "&code_challenge_method=S256" <>
            "&redirect_uri=#{URI.encode_www_form(redirect_uri)}" <>
            "&response_type=code" <>
            "&scope=read+write" <>
            "&state=#{state}"

        AuthState.store(state, %{
          code_verifier: code_verifier,
          client_id: client_id,
          client_secret: client_secret,
          redirect_uri: redirect_uri
        })

        json(conn, %{auth_url: auth_url, state: state})

      error ->
        Logger.error("[Bootstrap] Failed to get/register OAuth client: #{inspect(error)}")
        conn |> put_status(500) |> json(%{error: "Failed to initialize OAuth client"})
    end
  rescue
    e ->
      Logger.error("[Bootstrap] auth_start error: #{Exception.message(e)}")
      conn |> put_status(500) |> json(%{error: Exception.message(e)})
  end

  def auth_callback(conn, %{"code" => code, "state" => state}) do
    handle_auth_success(conn, code, state)
  end

  def auth_callback(conn, %{"error" => error}) do
    send_error_html(conn, error)
  end

  def auth_callback(conn, _params) do
    send_error_html(conn, "Invalid callback parameters")
  end

  def list_projects(conn, _params) do
    case OAuthClient.get_token() do
      {:ok, token} ->
        server_url = OAuthClient.get_server_url()
        url = "#{server_url}/api/projects"
        headers = [{"authorization", "Bearer #{token}"}]

        case Req.get(url, headers: headers) do
          {:ok, %{status: 200, body: body}} ->
            json(conn, body)

          {:ok, %{status: 401}} ->
            conn |> put_status(401) |> json(%{error: "Authentication expired"})

          {:ok, %{status: status, body: body}} ->
            conn |> put_status(502) |> json(%{error: "Server returned #{status}", details: body})

          {:error, reason} ->
            conn |> put_status(502) |> json(%{error: "Failed to reach server: #{inspect(reason)}"})
        end

      {:error, _} ->
        conn |> put_status(401) |> json(%{error: "Not authenticated. Call POST /api/bootstrap/auth/start first."})
    end
  end

  # -- Private -----------------------------------------------------------------

  defp handle_auth_success(conn, code, state) do
    case AuthState.get(state) do
      nil ->
        send_error_html(conn, "Unknown or expired auth state")

      %{code_verifier: code_verifier, client_id: client_id, client_secret: client_secret, redirect_uri: redirect_uri} ->
        AuthState.delete(state)
        server_url = OAuthClient.get_server_url()

        with {:ok, token_data} <-
               OAuthClient.exchange_code_for_token(code, code_verifier, client_id, client_secret, redirect_uri),
             {:ok, %{id: user_id, email: email}} <-
               OAuthClient.fetch_user_info(server_url, token_data["access_token"]),
             {:ok, _client_user} <-
               OAuthClient.save_client_user(user_id, email, token_data) do
          send_success_html(conn)
        else
          {:error, reason} ->
            Logger.error("[Bootstrap] Auth callback failed: #{inspect(reason)}")
            send_error_html(conn, "Authentication failed: #{inspect(reason)}")
        end
    end
  end

  defp send_success_html(conn) do
    html = """
    <!DOCTYPE html>
    <html>
    <head>
      <title>Authentication Successful</title>
      <style>
        body { font-family: system-ui, -apple-system, sans-serif; display: flex; justify-content: center; align-items: center; height: 100vh; margin: 0; background: linear-gradient(135deg, #667eea 0%, #764ba2 100%); }
        .container { background: white; padding: 3rem; border-radius: 1rem; box-shadow: 0 20px 60px rgba(0,0,0,0.3); text-align: center; max-width: 400px; }
        h1 { color: #2d3748; margin-bottom: 1rem; }
        p { color: #4a5568; font-size: 1.1rem; }
        .success { color: #48bb78; font-size: 3rem; margin-bottom: 1rem; }
      </style>
    </head>
    <body>
      <div class="container">
        <div class="success">&#10003;</div>
        <h1>Authentication Successful!</h1>
        <p>You can close this window and return to your terminal.</p>
      </div>
    </body>
    </html>
    """

    conn |> put_resp_content_type("text/html") |> send_resp(200, html)
  end

  defp send_error_html(conn, error) do
    html = """
    <!DOCTYPE html>
    <html>
    <head>
      <title>Authentication Failed</title>
      <style>
        body { font-family: system-ui, -apple-system, sans-serif; display: flex; justify-content: center; align-items: center; height: 100vh; margin: 0; background: linear-gradient(135deg, #f093fb 0%, #f5576c 100%); }
        .container { background: white; padding: 3rem; border-radius: 1rem; box-shadow: 0 20px 60px rgba(0,0,0,0.3); text-align: center; max-width: 400px; }
        h1 { color: #2d3748; margin-bottom: 1rem; }
        p { color: #4a5568; font-size: 1.1rem; }
        .error { color: #f56565; font-size: 3rem; margin-bottom: 1rem; }
      </style>
    </head>
    <body>
      <div class="container">
        <div class="error">&#10007;</div>
        <h1>Authentication Failed</h1>
        <p>#{error}</p>
      </div>
    </body>
    </html>
    """

    conn |> put_resp_content_type("text/html") |> send_resp(400, html)
  end
end
