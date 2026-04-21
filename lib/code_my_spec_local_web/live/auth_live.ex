defmodule CodeMySpecLocalWeb.AuthLive do
  @moduledoc """
  Sign in to CodeMySpec via OAuth PKCE.

  Kicks off the same browser-based flow as `BootstrapController.auth_start`,
  then renders the signed-in state (or the sign-in button) after callback.
  """
  use CodeMySpecLocalWeb, :live_view

  alias CodeMySpec.Auth.AuthState
  alias CodeMySpec.Auth.OAuthClient
  alias CodeMySpec.Projects

  @impl true
  def mount(_params, _session, socket) do
    {:ok, load_state(socket)}
  end

  @impl true
  def handle_event("sign_in", _params, socket) do
    server_url = OAuthClient.get_server_url()
    redirect_uri = "#{CodeMySpecLocalWeb.Endpoint.url()}/api/bootstrap/auth/callback"

    case OAuthClient.get_or_register_client(server_url, redirect_uri) do
      {:ok, client_id, client_secret} ->
        {code_verifier, code_challenge} = OAuthClient.generate_pkce_pair()
        state = OAuthClient.generate_state()

        AuthState.store(state, %{
          code_verifier: code_verifier,
          client_id: client_id,
          client_secret: client_secret,
          redirect_uri: redirect_uri
        })

        auth_url = build_auth_url(server_url, client_id, code_challenge, redirect_uri, state)
        {:noreply, redirect(socket, external: auth_url)}

      error ->
        {:noreply,
         put_flash(socket, :error, "Failed to start sign in: #{inspect(error)}")}
    end
  end

  def handle_event("sign_out", _params, socket) do
    OAuthClient.logout()

    {:noreply,
     socket
     |> put_flash(:info, "Signed out.")
     |> load_state()}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      projects={@projects}
      project={nil}
      page_title="Sign in"
    >
      <div class="max-w-md mx-auto py-12">
        <h1 class="text-3xl font-bold mb-2">Sign in</h1>
        <p class="text-base-content/70 mb-8">
          Authenticate this machine with your CodeMySpec account so the
          extension can call the API and MCP tools on your behalf.
        </p>

        <div :if={@authed} class="card bg-base-200 border border-base-300">
          <div class="card-body">
            <div class="flex items-center justify-between gap-4">
              <div class="min-w-0">
                <div class="text-sm opacity-60">Signed in as</div>
                <div class="font-mono text-sm truncate">{@email}</div>
              </div>
              <span class="badge badge-success shrink-0">Active</span>
            </div>
            <div class="card-actions justify-end mt-4">
              <button phx-click="sign_out" class="btn btn-ghost btn-sm">Sign out</button>
              <.link navigate={~p"/projects"} class="btn btn-primary btn-sm">
                Projects &rarr;
              </.link>
            </div>
          </div>
        </div>

        <div :if={!@authed}>
          <button phx-click="sign_in" class="btn btn-primary btn-lg w-full">
            Sign in with CodeMySpec
          </button>
          <p class="text-xs opacity-60 mt-3">
            Opens a browser window to complete OAuth PKCE. Token is stored
            locally in your extension database.
          </p>
        </div>
      </div>
    </Layouts.app>
    """
  end

  defp load_state(socket) do
    case OAuthClient.get_active_client_user() do
      {:ok, user} ->
        assign(socket,
          authed: not OAuthClient.token_expired?(user),
          email: user.email,
          projects: safe_list_projects()
        )

      _ ->
        assign(socket, authed: false, email: nil, projects: safe_list_projects())
    end
  end

  defp safe_list_projects do
    Projects.list_local_projects()
  rescue
    _ -> []
  end

  defp build_auth_url(server_url, client_id, code_challenge, redirect_uri, state) do
    query =
      URI.encode_query(
        client_id: client_id,
        code_challenge: code_challenge,
        code_challenge_method: "S256",
        redirect_uri: redirect_uri,
        response_type: "code",
        scope: "read write",
        state: state
      )

    "#{server_url}/oauth/authorize?#{query}"
  end
end
