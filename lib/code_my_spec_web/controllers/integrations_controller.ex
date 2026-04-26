defmodule CodeMySpecWeb.IntegrationsController do
  @moduledoc """
  Handles all OAuth provider flows — both social login and integration connect.

  ## Two Flows, One Callback

  **Login flow** (`oauth_flow: :login`):
  User clicks "Continue with GitHub/Google" on login/register page.
  Uses minimal scopes (email only). Finds or creates a user, persists
  the integration, and logs them in.

  **Integration flow** (`oauth_flow: :integration`):
  Authenticated user clicks "Connect GitHub/Google" in settings.
  Uses full scopes (repo access, analytics, etc.). Persists the integration
  to the existing user.

  The flow is determined by a session flag set during the request phase.
  Both flows share the same `/auth/:provider/callback` URL.
  """

  use CodeMySpecWeb, :controller

  alias CodeMySpec.{Accounts, Integrations, UserPreferences, Users}
  alias CodeMySpec.Users.Scope
  alias CodeMySpecWeb.UserAuth

  require Logger

  @doc """
  Initiates OAuth flow for social login.

  Uses minimal scopes (email/profile only) since this is for identity.
  Users can connect with full scopes later from settings.
  """
  def login(conn, %{"provider" => provider_str}) do
    provider = String.to_existing_atom(provider_str)

    case Integrations.authorize_login_url(provider) do
      {:ok, %{url: url, session_params: session_params}} ->
        conn
        |> put_session(:oauth_session_params, session_params)
        |> put_session(:oauth_provider, provider)
        |> put_session(:oauth_flow, :login)
        |> redirect(external: url)

      {:error, reason} ->
        Logger.error("Failed to generate social login URL for #{provider}: #{inspect(reason)}")

        conn
        |> put_flash(:error, "Unable to connect to #{provider_name(provider)}. Please try again.")
        |> redirect(to: ~p"/users/log-in")
    end
  end

  @doc """
  Initiates OAuth flow for integration connect (requires authenticated user).

  Uses full provider scopes for repo access, analytics, etc.
  """
  def request(conn, %{"provider" => provider_str}) do
    provider = String.to_existing_atom(provider_str)

    case Integrations.authorize_url(provider) do
      {:ok, %{url: url, session_params: session_params}} ->
        conn
        |> put_session(:oauth_session_params, session_params)
        |> put_session(:oauth_provider, provider)
        |> put_session(:oauth_flow, :integration)
        |> redirect(external: url)

      {:error, reason} ->
        Logger.error("Failed to generate OAuth URL for #{provider}: #{inspect(reason)}")

        conn
        |> put_flash(:error, "Failed to connect to #{provider_name(provider)}")
        |> redirect(to: ~p"/app/users/settings")
    end
  end

  @doc """
  Handles OAuth callback from provider. Dispatches to login or integration
  flow based on the session flag set during the request phase.
  """
  def callback(conn, params) do
    provider = get_session(conn, :oauth_provider)
    session_params = get_session(conn, :oauth_session_params) || %{}
    flow = get_session(conn, :oauth_flow) || :integration

    conn =
      conn
      |> delete_session(:oauth_session_params)
      |> delete_session(:oauth_provider)
      |> delete_session(:oauth_flow)

    case flow do
      :login -> handle_login_callback(conn, provider, params, session_params)
      :integration -> handle_integration_callback(conn, provider, params, session_params)
    end
  end

  @doc """
  Removes integration connection.
  """
  def delete(conn, %{"provider" => provider_str}) do
    provider = String.to_existing_atom(provider_str)
    scope = conn.assigns.current_scope

    case Integrations.delete_integration(scope, provider) do
      {:ok, _integration} ->
        conn
        |> put_flash(:info, "Disconnected from #{provider_name(provider)}")
        |> redirect(to: ~p"/app/users/settings")

      {:error, :not_found} ->
        conn
        |> put_flash(:error, "No connection found for #{provider_name(provider)}")
        |> redirect(to: ~p"/app/users/settings")
    end
  end

  # Login flow — find or create user, persist integration, log in

  defp handle_login_callback(conn, provider, params, session_params) do
    with :ok <- check_oauth_error(params),
         {:ok, %{user: normalized_user, token: token}} <-
           Integrations.handle_login_callback(provider, params, session_params),
         {:ok, user, status} <-
           Users.find_or_register_oauth_user(provider, normalized_user) do
      scope = Scope.for_user(user)
      account = Accounts.ensure_personal_account(scope)
      {:ok, _} = UserPreferences.select_active_account(scope, account.id)
      Integrations.save_integration(scope, provider, token, normalized_user)

      conn =
        if status == :new do
          put_session(conn, :user_return_to, ~p"/app/onboarding")
        else
          conn
        end

      UserAuth.log_in_user(conn, user, %{"remember_me" => "true"})
    else
      {:error, :missing_email} ->
        conn
        |> put_flash(
          :error,
          "We couldn't get an email address from #{provider_name(provider)}. " <>
            "Try a different sign-in method or grant email access."
        )
        |> redirect(to: ~p"/users/log-in")

      {:error, %Ecto.Changeset{} = changeset} ->
        Logger.error("Social login registration failed: #{inspect(changeset)}")

        conn
        |> put_flash(:error, "Unable to create account. The email may already be in use.")
        |> redirect(to: ~p"/users/log-in")

      {:error, reason} ->
        Logger.error("Social login failed for #{provider}: #{inspect(reason)}")

        conn
        |> put_flash(:error, format_oauth_error(params, reason))
        |> redirect(to: ~p"/users/log-in")
    end
  end

  # Integration flow — persist integration for existing authenticated user

  defp handle_integration_callback(conn, provider, params, session_params) do
    scope = conn.assigns.current_scope

    case handle_oauth_result(scope, provider, params, session_params) do
      {:ok, _integration} ->
        conn
        |> put_flash(:info, "Successfully connected to #{provider_name(provider)}")
        |> redirect(to: ~p"/app/users/settings")

      {:error, %Ecto.Changeset{} = changeset} ->
        Logger.error("Failed to persist integration: #{inspect(changeset)}")

        conn
        |> put_flash(:error, "Failed to save integration")
        |> redirect(to: ~p"/app/users/settings")

      {:error, reason} ->
        Logger.error("OAuth callback failed for #{provider}: #{inspect(reason)}")

        conn
        |> put_flash(:error, format_oauth_error(params, reason))
        |> redirect(to: ~p"/app/users/settings")
    end
  end

  defp handle_oauth_result(nil, _provider, _params, _session_params) do
    {:error, :not_authenticated}
  end

  defp handle_oauth_result(%Scope{} = scope, provider, params, session_params) do
    case Map.get(params, "error") do
      nil -> Integrations.handle_callback(scope, provider, params, session_params)
      error -> {:error, error}
    end
  end

  defp check_oauth_error(%{"error" => _} = params), do: {:error, {:oauth_error, params}}
  defp check_oauth_error(_params), do: :ok

  defp format_oauth_error(%{"error" => "access_denied"}, _reason) do
    "You denied access. Please try again if you want to connect."
  end

  defp format_oauth_error(%{"error" => error, "error_description" => description}, _reason) do
    "OAuth error: #{description} (#{error})"
  end

  defp format_oauth_error(%{"error" => error}, _reason) do
    "OAuth error: #{error}"
  end

  defp format_oauth_error(_params, :not_authenticated) do
    "You must be logged in to connect integrations"
  end

  defp format_oauth_error(_params, :unsupported_provider) do
    "This provider is not supported"
  end

  defp format_oauth_error(_params, {:oauth_error, error_params}) do
    format_oauth_error(error_params, nil)
  end

  defp format_oauth_error(_params, _reason) do
    "Failed to complete OAuth flow. Please try again."
  end

  defp provider_name(:github), do: "GitHub"
  defp provider_name(:gitlab), do: "GitLab"
  defp provider_name(:bitbucket), do: "Bitbucket"
  defp provider_name(:google), do: "Google"
  defp provider_name(provider), do: to_string(provider)
end
