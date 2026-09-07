defmodule CodeMySpecWeb.ContentSyncController do
  @moduledoc """
  Controller for handling content synchronization from server to client appliances.

  This endpoint receives content pushed from the CodeMySpec SaaS server to client
  appliances. It validates the deployment key before accepting content.
  """

  use CodeMySpecWeb, :controller

  alias CodeMySpec.Content
  alias CodeMySpec.Content.Pull

  action_fallback CodeMySpecWeb.FallbackController

  @doc """
  Handles content sync POST requests from the server.

  Validates the deployment key against the DEPLOY_KEY environment variable,
  then processes the content payload.

  ## Expected Payload

      %{
        "content" => [%{slug, title, content_type, ...}, ...],
        "synced_at" => ISO8601 datetime
      }

  ## Authentication

  Requires Bearer token in Authorization header matching DEPLOY_KEY env var.
  """
  def sync(conn, %{"content" => content_list, "synced_at" => _synced_at}) do
    with :ok <- validate_deploy_key(conn),
         {:ok, _result} <- sync_content(content_list) do
      conn
      |> put_status(:ok)
      |> json(%{
        status: "success",
        synced_count: length(content_list),
        message: "Content synced successfully"
      })
    else
      # An aged-out token, not a wrong one. `reason` is what tells the app to
      # renew and retry rather than go looking at its configuration —
      # criterion 8023 is precisely this distinction.
      {:error, :expired} ->
        conn
        |> put_status(:unauthorized)
        |> json(%{status: "error", error: "Access token expired", reason: "expired"})

      {:error, :unauthorized} ->
        conn
        |> put_status(:unauthorized)
        |> json(%{status: "error", error: "Invalid deployment key", reason: "invalid"})

      {:error, :missing_deploy_key} ->
        conn
        |> put_status(:unauthorized)
        |> json(%{status: "error", error: "Missing deployment key", reason: "invalid"})

      {:error, :deploy_key_not_configured} ->
        conn
        |> put_status(:internal_server_error)
        |> json(%{status: "error", error: "Deploy key not configured on server"})

      {:error, reason} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{status: "error", error: inspect(reason)})
    end
  end

  # Authenticate before complaining about the body. A malformed request from
  # an unauthenticated caller is still an unauthenticated caller, and telling
  # it which parameters it is missing hands the endpoint's contract to someone
  # who has not proved they may use it — criterion 8045 is that what the
  # environment holds opens none of the five surfaces, and "opens" includes
  # learning their shape.
  def sync(conn, _params) do
    case validate_deploy_key(conn) do
      :ok ->
        conn
        |> put_status(:bad_request)
        |> json(%{status: "error", error: "Missing required parameters: content, synced_at"})

      {:error, :expired} ->
        conn
        |> put_status(:unauthorized)
        |> json(%{status: "error", error: "Access token expired", reason: "expired"})

      {:error, reason} when reason in [:unauthorized, :missing_deploy_key] ->
        conn
        |> put_status(:unauthorized)
        |> json(%{status: "error", error: "Unauthorized", reason: "invalid"})

      {:error, :deploy_key_not_configured} ->
        conn
        |> put_status(:internal_server_error)
        |> json(%{status: "error", error: "Deploy key not configured on server"})
    end
  end

  @doc """
  Pull trigger (story 713). Validates the deploy key, then starts an async
  sync that fetches the manifest from `manifest_url`, verifies the blob hash,
  and atomically replaces local content. Returns 202 immediately; auth
  failures return 401.
  """
  def pull(conn, %{"manifest_url" => manifest_url}) do
    case validate_deploy_key(conn) do
      :ok ->
        run_pull(manifest_url)

        conn
        |> put_status(:accepted)
        |> json(%{status: "accepted", sync_id: Ecto.UUID.generate()})

      {:error, :expired} ->
        conn
        |> put_status(:unauthorized)
        |> json(%{status: "error", error: "Access token expired", reason: "expired"})

      {:error, :unauthorized} ->
        conn |> put_status(:unauthorized) |> json(%{status: "error", error: "Invalid deployment key", reason: "invalid"})

      {:error, :missing_deploy_key} ->
        conn |> put_status(:unauthorized) |> json(%{status: "error", error: "Missing deployment key"})

      {:error, :deploy_key_not_configured} ->
        conn
        |> put_status(:internal_server_error)
        |> json(%{status: "error", error: "Deploy key not configured on server"})
    end
  end

  def pull(conn, _params) do
    conn
    |> put_status(:bad_request)
    |> json(%{status: "error", error: "Missing required parameter: manifest_url"})
  end

  # Run the pull async in production; synchronously in tests (so it shares the
  # ExUnit sandbox connection instead of racing the test process's lifetime).
  defp run_pull(manifest_url) do
    if Application.get_env(:code_my_spec, :content_pull_async, true) do
      Task.start(fn -> Pull.run(manifest_url) end)
    else
      Pull.run(manifest_url)
    end
  end

  # ============================================================================
  # Private Functions - Authentication
  # ============================================================================

  @spec validate_deploy_key(Plug.Conn.t()) :: :ok | {:error, atom()}
  # A short-lived access token is accepted in place of the configured key.
  # Only in place of it: the token path does not identify a project here, it
  # only proves the caller exchanged a refresh secret we issued. This surface
  # authorizes on "the key I was configured with", and widening it to "any
  # project" would be a different endpoint wearing this one's name.
  defp validate_deploy_key(conn) do
    case CodeMySpecWeb.AppCredential.token(conn) do
      {:ok, _project} -> :ok
      {:error, :expired} -> {:error, :expired}
      {:error, _} -> validate_configured_deploy_key(conn)
    end
  end

  defp validate_configured_deploy_key(conn) do
    with {:ok, expected_key} <- get_expected_deploy_key(),
         {:ok, provided_key} <- extract_bearer_token(conn) do
      if secure_compare(expected_key, provided_key) do
        :ok
      else
        {:error, :unauthorized}
      end
    end
  end

  @spec get_expected_deploy_key() :: {:ok, String.t()} | {:error, :deploy_key_not_configured}
  defp get_expected_deploy_key do
    case Application.get_env(:code_my_spec, :deploy_key) do
      nil -> {:error, :deploy_key_not_configured}
      "" -> {:error, :deploy_key_not_configured}
      key -> {:ok, key}
    end
  end

  @spec extract_bearer_token(Plug.Conn.t()) :: {:ok, String.t()} | {:error, :missing_deploy_key}
  defp extract_bearer_token(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token] -> {:ok, token}
      _ -> {:error, :missing_deploy_key}
    end
  end

  @spec secure_compare(String.t(), String.t()) :: boolean()
  defp secure_compare(left, right) do
    # Use constant-time comparison to prevent timing attacks
    if byte_size(left) == byte_size(right) do
      Plug.Crypto.secure_compare(left, right)
    else
      # Still do a comparison to maintain constant time
      Plug.Crypto.secure_compare(left, left)
      false
    end
  end

  # ============================================================================
  # Private Functions - Content Sync
  # ============================================================================

  @spec sync_content([map()]) :: {:ok, term()} | {:error, term()}
  defp sync_content(content_list) do
    Content.sync_content(content_list)
  end
end
