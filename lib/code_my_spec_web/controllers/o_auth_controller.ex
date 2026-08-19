defmodule CodeMySpecWeb.OAuthController do
  @moduledoc """
  OAuth2 Authorization Server Controller

  Handles OAuth2 authorization flow for MCP clients.
  """

  use CodeMySpecWeb, :controller

  alias CodeMySpec.Oauth
  alias ExOauth2Provider.{Authorization, Token}

  @doc """
  GET /oauth/authorize
  Shows the authorization page to the user
  """
  # First-party clients that skip the consent screen for already-authenticated
  # users. The CLI's `/codemyspec:authenticate` flow opens the user's browser
  # against /oauth/authorize from the same machine they're already signed
  # into; rendering a consent page there would be friction for no security
  # gain — they're already on a session bound to the same account.
  @trusted_clients ~w(codemyspec-cli)

  def authorize(conn, params) do
    case conn.assigns[:current_scope] do
      nil ->
        # User not authenticated, redirect to login with return path
        return_to = "/oauth/authorize?" <> URI.encode_query(params)

        conn
        |> put_session(:oauth_params, params)
        |> put_session(:user_return_to, return_to)
        |> redirect(to: ~p"/users/log-in")

      scope ->
        scope.user
        |> Authorization.preauthorize(params, otp_app: :code_my_spec)
        |> handle_preauthorize(conn, scope, params)
    end
  end

  defp handle_preauthorize({:ok, %{uid: uid} = _client, _scopes}, conn, scope, params)
       when uid in @trusted_clients do
    authorize_trusted_client(conn, scope, params)
  end

  defp handle_preauthorize({:ok, client, scopes}, conn, _scope, params) do
    render(conn, :authorize, client: client, scopes: scopes, params: params)
  end

  defp handle_preauthorize({:redirect, redirect_uri}, conn, _scope, _params) do
    redirect(conn, external: redirect_uri)
  end

  defp handle_preauthorize({:native_redirect, payload}, conn, _scope, _params) do
    json(conn, payload)
  end

  defp handle_preauthorize({:error, error, http_status}, conn, _scope, params) do
    require Logger

    Logger.error("OAuth preauthorize failed: #{inspect(error)}, params: #{inspect(params)}")

    conn
    |> put_status(http_status)
    |> put_flash(:error, "OAuth authorization error: #{inspect(error)}")
    |> redirect(to: ~p"/")
  end

  defp authorize_trusted_client(conn, scope, params) do
    case Authorization.authorize(scope.user, params, otp_app: :code_my_spec) do
      {:redirect, redirect_uri} ->
        redirect(conn, external: redirect_uri)

      {:native_redirect, payload} ->
        json(conn, payload)

      {:error, error, http_status} ->
        require Logger

        Logger.error(
          "Trusted-client OAuth authorize failed: #{inspect(error)}, params: #{inspect(params)}"
        )

        conn
        |> put_status(http_status)
        |> put_flash(:error, "OAuth authorization error: #{inspect(error)}")
        |> redirect(to: ~p"/")
    end
  end

  @doc """
  POST /oauth/authorize
  Handles the user's authorization decision
  """
  def create(conn, params) do
    case conn.assigns[:current_scope] do
      nil ->
        conn
        |> put_flash(:error, "Authentication required")
        |> redirect(to: ~p"/users/log-in")

      scope ->
        case Authorization.authorize(scope.user, params, otp_app: :code_my_spec) do
          {:redirect, redirect_uri} ->
            redirect(conn, external: redirect_uri)

          {:native_redirect, payload} ->
            json(conn, payload)

          {:error, error, http_status} ->
            conn
            |> put_status(http_status)
            |> put_flash(:error, "Authorization failed: #{inspect(error)}")
            |> redirect(
              to:
                ~p"/oauth/authorize?" <>
                  URI.encode_query(
                    Map.take(params, [
                      "client_id",
                      "redirect_uri",
                      "scope",
                      "response_type",
                      "state"
                    ])
                  )
            )
        end
    end
  end

  @doc """
  DELETE /oauth/authorize
  Handles authorization denial
  """
  def delete(conn, params) do
    case conn.assigns[:current_scope] do
      nil ->
        conn
        |> put_flash(:error, "Authentication required")
        |> redirect(to: ~p"/users/log-in")

      scope ->
        case Authorization.deny(scope.user, params, otp_app: :code_my_spec) do
          {:redirect, redirect_uri} ->
            redirect(conn, external: redirect_uri)

          {:error, error, http_status} ->
            conn
            |> put_status(http_status)
            |> put_flash(:error, "Authorization denial failed: #{inspect(error)}")
            |> redirect(to: ~p"/")
        end
    end
  end

  @doc """
  POST /oauth/token
  Handles token requests (authorization code exchange, refresh tokens)
  """
  def token(conn, params) do
    case Token.grant(params, otp_app: :code_my_spec) do
      {:ok, access_token} ->
        json(conn, %{
          access_token: access_token.access_token,
          refresh_token: access_token.refresh_token,
          expires_in: access_token.expires_in,
          token_type: "Bearer",
          scope: access_token.scope
        })

      {:error, error, http_status} ->
        conn
        |> put_status(http_status)
        |> json(%{error: "invalid_request", error_description: inspect(error)})
    end
  end

  @doc """
  POST /oauth/revoke
  Handles token revocation
  """
  def revoke(conn, params) do
    case Token.revoke(params, otp_app: :code_my_spec) do
      {:ok, _} ->
        conn
        |> put_status(:ok)
        |> json(%{})

      {:error, error, http_status} ->
        conn
        |> put_status(http_status)
        |> json(%{error: "invalid_request", error_description: inspect(error)})
    end
  end

  @doc """
  GET /.well-known/oauth-protected-resource
  GET /.well-known/oauth-protected-resource/*path
  MCP Protected Resource Metadata (RFC 9728)

  `resource` has to name the exact URL a client is connecting to, not a
  shared parent. Every mount under `/mcp` — `/mcp/harness`, `/mcp/stories`,
  the rest — used to get back the same `"resource": "<base_url>/mcp"`
  regardless of which one asked, because this ignored `*path` entirely.
  RFC 9728 doesn't mandate exact-match resource validation, but the MCP
  authorization spec's clients are free to enforce it, and got a value that
  could never match what they'd actually connected to — a discovery
  response that fails validation on every single request, independent of
  any token or auth state. Reachable from
  `.well-known/oauth-protected-resource` bare (no suffix — the RFC 9728
  default, host-wide) as well as the per-resource suffixed form.
  """
  def protected_resource_metadata(conn, params) do
    base_url = get_base_url()
    resource = resource_url(base_url, params)

    conn
    |> put_resp_header("content-type", "application/json")
    |> put_resp_header("access-control-allow-origin", "*")
    |> json(%{
      "resource" => resource,
      "authorization_servers" => [base_url],
      "scopes_supported" => ["read", "write"],
      "bearer_methods_supported" => ["header"]
    })
  end

  defp resource_url(base_url, %{"path" => path}) when is_list(path) and path != [],
    do: Enum.join([base_url | path], "/")

  defp resource_url(base_url, _params), do: "#{base_url}/mcp"

  @doc """
  GET /.well-known/oauth-authorization-server
  MCP Authorization Server Metadata (RFC 8414)
  """
  def authorization_server_metadata(conn, _params) do
    base_url = get_base_url()

    conn
    |> put_resp_header("content-type", "application/json")
    |> put_resp_header("access-control-allow-origin", "*")
    |> json(%{
      "issuer" => base_url,
      "authorization_endpoint" => "#{base_url}/oauth/authorize",
      "token_endpoint" => "#{base_url}/oauth/token",
      "registration_endpoint" => "#{base_url}/oauth/register",
      "scopes_supported" => ["read", "write"],
      "response_types_supported" => ["code"],
      "grant_types_supported" => ["authorization_code", "client_credentials"],
      "code_challenge_methods_supported" => ["S256"],
      "token_endpoint_auth_methods_supported" => ["client_secret_post", "none"],
      "revocation_endpoint" => "#{base_url}/oauth/revoke"
    })
  end

  @doc """
  POST /oauth/register
  Dynamic Client Registration for MCP
  """
  def register(conn, params) do
    case create_oauth_application(params) do
      {:ok, application} ->
        conn
        |> put_status(201)
        |> json(%{
          "client_id" => application.uid,
          "client_secret" => application.secret,
          "client_name" => application.name,
          "redirect_uris" => String.split(application.redirect_uri || "", " ", trim: true),
          "grant_types" => ["authorization_code"],
          "response_types" => ["code"],
          "scope" => application.scopes
        })

      {:error, changeset} ->
        conn
        |> put_status(400)
        |> json(%{
          "error" => "invalid_client_metadata",
          "error_description" => format_errors(changeset)
        })
    end
  end

  defp create_oauth_application(params) do
    Oauth.register_application(%{
      name: params["client_name"] || "MCP Client",
      redirect_uri: (params["redirect_uris"] || []) |> Enum.join(" "),
      scopes: "read write",
      uid: generate_client_id(),
      secret: generate_client_secret()
    })
  end

  defp generate_client_id,
    do: "mcp_" <> (:crypto.strong_rand_bytes(16) |> Base.url_encode64(padding: false))

  defp generate_client_secret,
    do: :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)

  defp format_errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, _opts} -> msg end)
    |> Enum.map_join("; ", fn {field, errors} -> "#{field}: #{Enum.join(errors, ", ")}" end)
  end

  defp get_base_url do
    CodeMySpecWeb.Endpoint.url()
  end
end
