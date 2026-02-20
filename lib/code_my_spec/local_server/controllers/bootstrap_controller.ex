defmodule CodeMySpec.LocalServer.Controllers.BootstrapController do
  @moduledoc """
  HTTP endpoints for agent-driven auth and project initialization.

  These endpoints allow the agent to handle login, project selection, and
  config init directly via the local server (port 4002), eliminating the
  need for interactive `cms login` / `cms init` CLI commands.

  All endpoints use `LocalOnly` (localhost check) but NOT `LocalScope`
  (no .code_my_spec/config.yml required).
  """

  import Plug.Conn

  require Logger

  alias CodeMySpec.AgentTasks.ProjectSetup
  alias CodeMySpec.Auth.OAuthClient
  alias CodeMySpec.Environments.Environment
  alias CodeMySpec.LocalServer.AuthState
  alias CodeMySpec.LocalServer.Config, as: ServerConfig
  alias CodeMySpec.Users.Scope

  # --- Auth Status ---

  @doc """
  Check if the user is authenticated.

  Returns `{"authenticated": true, "email": "..."}` or `{"authenticated": false}`.
  """
  def auth_status(conn) do
    case OAuthClient.get_active_client_user() do
      {:ok, user} ->
        if OAuthClient.token_expired?(user) do
          json_response(conn, 200, %{authenticated: false})
        else
          json_response(conn, 200, %{authenticated: true, email: user.email})
        end

      {:error, _} ->
        json_response(conn, 200, %{authenticated: false})
    end
  end

  # --- Auth Start ---

  @doc """
  Start an OAuth PKCE flow.

  Generates a PKCE pair and state, stores them in AuthState, and returns
  the authorization URL for the user to visit in their browser.

  Returns `{"auth_url": "...", "state": "..."}`.
  """
  def auth_start(conn) do
    server_url = OAuthClient.get_server_url()
    redirect_uri = "#{ServerConfig.url()}/api/bootstrap/auth/callback"

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

        json_response(conn, 200, %{auth_url: auth_url, state: state})

      error ->
        Logger.error("[Bootstrap] Failed to get/register OAuth client: #{inspect(error)}")
        json_response(conn, 500, %{error: "Failed to initialize OAuth client"})
    end
  rescue
    e ->
      Logger.error("[Bootstrap] auth_start error: #{Exception.message(e)}")
      json_response(conn, 500, %{error: Exception.message(e)})
  end

  # --- Auth Callback ---

  @doc """
  Handle the OAuth callback after user authorizes in browser.

  Exchanges the authorization code for tokens, saves the user, and renders
  a success HTML page.
  """
  def auth_callback(conn) do
    conn = fetch_query_params(conn)

    case conn.query_params do
      %{"code" => code, "state" => state} ->
        handle_auth_success(conn, code, state)

      %{"error" => error} ->
        send_error_html(conn, error)

      _ ->
        send_error_html(conn, "Invalid callback parameters")
    end
  end

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

  # --- List Projects ---

  @doc """
  List available projects from the CodeMySpec server.

  Requires authentication. Returns `{"projects": [...]}`.
  """
  def list_projects(conn) do
    case OAuthClient.get_token() do
      {:ok, token} ->
        server_url = OAuthClient.get_server_url()
        url = "#{server_url}/api/projects"
        headers = [{"authorization", "Bearer #{token}"}]

        case Req.get(url, headers: headers) do
          {:ok, %{status: 200, body: body}} ->
            json_response(conn, 200, body)

          {:ok, %{status: 401}} ->
            json_response(conn, 401, %{error: "Authentication expired"})

          {:ok, %{status: status, body: body}} ->
            json_response(conn, 502, %{error: "Server returned #{status}", details: body})

          {:error, reason} ->
            json_response(conn, 502, %{error: "Failed to reach server: #{inspect(reason)}"})
        end

      {:error, _} ->
        json_response(conn, 401, %{error: "Not authenticated. Call POST /api/bootstrap/auth/start first."})
    end
  end

  # --- Init Project ---

  @doc """
  Initialize .code_my_spec/config.yml for the given project.

  Requires `X-Working-Dir` header and `project_id` in body.
  Fetches project details from server and writes config.

  Returns `{"status": "ok", "config_path": "..."}`.
  """
  def init_project(conn) do
    working_dir = conn.assigns[:working_dir]
    project_id = conn.body_params["project_id"]

    cond do
      is_nil(working_dir) ->
        json_response(conn, 400, %{error: "X-Working-Dir header is required"})

      is_nil(project_id) || project_id == "" ->
        json_response(conn, 400, %{error: "project_id is required in request body"})

      true ->
        do_init_project(conn, working_dir, project_id)
    end
  end

  defp do_init_project(conn, working_dir, project_id) do
    with {:ok, token} <- OAuthClient.get_token(),
         {:ok, projects} <- fetch_projects(token),
         {:ok, project} <- find_project(projects, project_id) do
      write_project_config(conn, working_dir, project)
    else
      {:error, :not_authenticated} ->
        json_response(conn, 401, %{error: "Not authenticated"})

      {:error, :not_found} ->
        json_response(conn, 404, %{error: "Project not found: #{project_id}"})

      {:error, reason} ->
        json_response(conn, 502, %{error: "Server error: #{inspect(reason)}"})
    end
  end

  defp fetch_projects(token) do
    server_url = OAuthClient.get_server_url()
    url = "#{server_url}/api/projects"
    headers = [{"authorization", "Bearer #{token}"}]

    case Req.get(url, headers: headers) do
      {:ok, %{status: 200, body: %{"projects" => projects}}} -> {:ok, projects}
      {:ok, %{status: status}} -> {:error, "Server returned #{status}"}
      {:error, reason} -> {:error, "Failed to reach server: #{inspect(reason)}"}
    end
  end

  defp find_project(projects, project_id) do
    case Enum.find(projects, &(&1["id"] == project_id)) do
      nil -> {:error, :not_found}
      project -> {:ok, project}
    end
  end

  # --- Setup Project ---

  @doc """
  Run project setup check and return the setup prompt.

  Builds a minimal scope from the working directory (no config.yml needed)
  and calls ProjectSetup.command directly.

  Returns `{"prompt": "..."}`.
  """
  def setup_project(conn) do
    working_dir = conn.assigns[:working_dir]

    if is_nil(working_dir) do
      json_response(conn, 400, %{error: "X-Working-Dir header is required"})
    else
      env = Environment.new(:local, working_dir)
      scope = %Scope{environment: env}
      {:ok, prompt} = ProjectSetup.command(scope, %{})
      json_response(conn, 200, %{prompt: prompt})
    end
  end

  defp write_project_config(conn, working_dir, project) do
    app_name = detect_app_name(working_dir) || "my_app"
    module_name = Macro.camelize(app_name)

    config = %{
      "project_id" => project["id"],
      "account_id" => project["account_id"],
      "module_name" => project["module_name"] || module_name,
      "name" => project["name"],
      "description" => project["description"],
      "code_repo" => project["code_repo"],
      "docs_repo" => project["docs_repo"],
      "client_api_url" => project["client_api_url"]
    }

    config_dir = Path.join(working_dir, ".code_my_spec")
    config_path = Path.join(config_dir, "config.yml")

    File.mkdir_p!(config_dir)

    yaml =
      config
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)
      |> Enum.map_join("\n", fn {key, value} -> format_yaml_entry(key, value) end)
      |> Kernel.<>("\n")

    case File.write(config_path, yaml) do
      :ok ->
        json_response(conn, 200, %{status: "ok", config_path: config_path, project_name: project["name"]})

      {:error, reason} ->
        json_response(conn, 500, %{error: "Failed to write config: #{inspect(reason)}"})
    end
  end

  # --- Helpers ---

  defp json_response(conn, status, body) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(body))
  end

  defp send_success_html(conn) do
    html = """
    <!DOCTYPE html>
    <html>
    <head>
      <title>Authentication Successful</title>
      <style>
        body {
          font-family: system-ui, -apple-system, sans-serif;
          display: flex;
          justify-content: center;
          align-items: center;
          height: 100vh;
          margin: 0;
          background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
        }
        .container {
          background: white;
          padding: 3rem;
          border-radius: 1rem;
          box-shadow: 0 20px 60px rgba(0,0,0,0.3);
          text-align: center;
          max-width: 400px;
        }
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

    conn
    |> put_resp_content_type("text/html")
    |> send_resp(200, html)
  end

  defp send_error_html(conn, error) do
    html = """
    <!DOCTYPE html>
    <html>
    <head>
      <title>Authentication Failed</title>
      <style>
        body {
          font-family: system-ui, -apple-system, sans-serif;
          display: flex;
          justify-content: center;
          align-items: center;
          height: 100vh;
          margin: 0;
          background: linear-gradient(135deg, #f093fb 0%, #f5576c 100%);
        }
        .container {
          background: white;
          padding: 3rem;
          border-radius: 1rem;
          box-shadow: 0 20px 60px rgba(0,0,0,0.3);
          text-align: center;
          max-width: 400px;
        }
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

    conn
    |> put_resp_content_type("text/html")
    |> send_resp(400, html)
  end

  defp detect_app_name(working_dir) do
    mix_exs = Path.join(working_dir, "mix.exs")

    with true <- File.exists?(mix_exs),
         {:ok, content} <- File.read(mix_exs),
         [_, app_name] <- Regex.run(~r/app:\s*:(\w+)/, content) do
      app_name
    else
      _ -> nil
    end
  end

  defp format_yaml_entry(key, value) when is_list(value) do
    items = Enum.map_join(value, "\n", fn item -> "  - #{format_yaml_value(item)}" end)
    "#{key}:\n#{items}"
  end

  defp format_yaml_entry(key, value) do
    "#{key}: #{format_yaml_value(value)}"
  end

  defp format_yaml_value(value) when is_binary(value) do
    if String.contains?(value, [":", "@"]) do
      "\"#{value}\""
    else
      value
    end
  end

  defp format_yaml_value(value), do: value
end
