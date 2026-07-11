defmodule CodeMySpecWeb.UserLive.Settings do
  use CodeMySpecWeb, :live_view

  on_mount {CodeMySpecWeb.UserAuth, :require_sudo_mode}

  alias CodeMySpec.Integrations
  alias CodeMySpec.Users

  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} current_path={@current_path} pending_notifications={@pending_notifications}>
      <div class="text-center">
        <.header>
          Account Settings
          <:subtitle>Manage your account email address and password settings</:subtitle>
        </.header>
      </div>

      <.form for={@email_form} id="email_form" phx-submit="update_email" phx-change="validate_email">
        <.input
          field={@email_form[:email]}
          type="email"
          label="Email"
          autocomplete="username"
          required
        />
        <.button phx-disable-with="Changing...">Change Email</.button>
      </.form>

      <div class="divider" />

      <.form
        for={@password_form}
        id="password_form"
        action={~p"/app/users/update-password"}
        method="post"
        phx-change="validate_password"
        phx-submit="update_password"
        phx-trigger-action={@trigger_submit}
      >
        <input
          name={@password_form[:email].name}
          type="hidden"
          id="hidden_user_email"
          autocomplete="username"
          value={@current_email}
        />
        <.input
          field={@password_form[:password]}
          type="password"
          label="New password"
          autocomplete="new-password"
          required
        />
        <.input
          field={@password_form[:password_confirmation]}
          type="password"
          label="Confirm new password"
          autocomplete="new-password"
        />
        <.button phx-disable-with="Saving...">
          Save Password
        </.button>
      </.form>

      <div class="divider" />

      <div class="space-y-4">
        <h3 class="text-lg font-semibold">Connected Services</h3>

        <div class="border rounded-lg p-4 flex items-center justify-between">
          <div class="flex items-center gap-3">
            <svg class="w-8 h-8" viewBox="0 0 24 24" fill="currentColor">
              <path d="M12 0C5.37 0 0 5.37 0 12c0 5.31 3.435 9.795 8.205 11.385.6.105.825-.255.825-.57 0-.285-.015-1.23-.015-2.235-3.015.555-3.795-.735-4.035-1.41-.135-.345-.72-1.41-1.23-1.695-.42-.225-1.02-.78-.015-.795.945-.015 1.62.87 1.845 1.23 1.08 1.815 2.805 1.305 3.495.99.105-.78.42-1.305.765-1.605-2.67-.3-5.46-1.335-5.46-5.925 0-1.305.465-2.385 1.23-3.225-.12-.3-.54-1.53.12-3.18 0 0 1.005-.315 3.3 1.23.96-.27 1.98-.405 3-.405s2.04.135 3 .405c2.295-1.56 3.3-1.23 3.3-1.23.66 1.65.24 2.88.12 3.18.765.84 1.23 1.905 1.23 3.225 0 4.605-2.805 5.625-5.475 5.925.435.375.81 1.095.81 2.22 0 1.605-.015 2.895-.015 3.3 0 .315.225.69.825.57A12.02 12.02 0 0024 12c0-6.63-5.37-12-12-12z" />
            </svg>
            <div>
              <div class="font-medium">GitHub</div>
              <%= if @github_connected do %>
                <div class="text-sm text-green-600">Connected</div>
              <% else %>
                <div class="text-sm text-gray-500">Not connected</div>
              <% end %>
            </div>
          </div>

          <%= if @github_connected do %>
            <button
              type="button"
              class="btn btn-sm btn-outline btn-error"
              phx-click={show_confirm("confirm-disconnect-github")}
            >
              Disconnect
            </button>
            <.link
              id="disconnect-github-link"
              href={~p"/auth/github"}
              method="delete"
              class="hidden"
              aria-hidden="true"
              tabindex="-1"
            >
              Disconnect
            </.link>
            <.confirm_dialog
              id="confirm-disconnect-github"
              title="Disconnect GitHub?"
              message="You'll need to reconnect to use GitHub features."
              confirm_label="Disconnect"
              on_confirm={JS.dispatch("click", to: "#disconnect-github-link")}
            />
          <% else %>
            <.link href={~p"/auth/github"} class="btn btn-sm btn-primary">
              Connect GitHub
            </.link>
          <% end %>
        </div>

        <div class="border rounded-lg p-4 flex items-center justify-between">
          <div class="flex items-center gap-3">
            <svg class="w-8 h-8" viewBox="0 0 24 24" fill="currentColor">
              <path
                d="M22.56 12.25c0-.78-.07-1.53-.2-2.25H12v4.26h5.92c-.26 1.37-1.04 2.53-2.21 3.31v2.77h3.57c2.08-1.92 3.28-4.74 3.28-8.09z"
                fill="#4285F4"
              />
              <path
                d="M12 23c2.97 0 5.46-.98 7.28-2.66l-3.57-2.77c-.98.66-2.23 1.06-3.71 1.06-2.86 0-5.29-1.93-6.16-4.53H2.18v2.84C3.99 20.53 7.7 23 12 23z"
                fill="#34A853"
              />
              <path
                d="M5.84 14.09c-.22-.66-.35-1.36-.35-2.09s.13-1.43.35-2.09V7.07H2.18C1.43 8.55 1 10.22 1 12s.43 3.45 1.18 4.93l2.85-2.22.81-.62z"
                fill="#FBBC05"
              />
              <path
                d="M12 5.38c1.62 0 3.06.56 4.21 1.64l3.15-3.15C17.45 2.09 14.97 1 12 1 7.7 1 3.99 3.47 2.18 7.07l3.66 2.84c.87-2.6 3.3-4.53 6.16-4.53z"
                fill="#EA4335"
              />
            </svg>
            <div>
              <div class="font-medium">Google</div>
              <%= if @google_connected do %>
                <div class="text-sm text-green-600">Connected</div>
              <% else %>
                <div class="text-sm text-gray-500">Not connected</div>
              <% end %>
            </div>
          </div>

          <%= if @google_connected do %>
            <button
              type="button"
              class="btn btn-sm btn-outline btn-error"
              phx-click={show_confirm("confirm-disconnect-google")}
            >
              Disconnect
            </button>
            <.link
              id="disconnect-google-link"
              href={~p"/auth/google"}
              method="delete"
              class="hidden"
              aria-hidden="true"
              tabindex="-1"
            >
              Disconnect
            </.link>
            <.confirm_dialog
              id="confirm-disconnect-google"
              title="Disconnect Google?"
              message="You'll need to reconnect to use Google features."
              confirm_label="Disconnect"
              on_confirm={JS.dispatch("click", to: "#disconnect-google-link")}
            />
          <% else %>
            <.link href={~p"/auth/google"} class="btn btn-sm btn-primary">
              Connect Google
            </.link>
          <% end %>
        </div>
      </div>
    </Layouts.app>
    """
  end

  def mount(%{"token" => token}, _session, socket) do
    socket =
      case Users.update_user_email(socket.assigns.current_scope.user, token) do
        {:ok, _user} ->
          put_flash(socket, :info, "Email changed successfully.")

        {:error, _} ->
          put_flash(socket, :error, "Email change link is invalid or it has expired.")
      end

    {:ok, push_navigate(socket, to: ~p"/app/users/settings")}
  end

  def mount(_params, _session, socket) do
    user = socket.assigns.current_scope.user
    scope = socket.assigns.current_scope
    email_changeset = Users.change_user_email(user, %{}, validate_unique: false)
    password_changeset = Users.change_user_password(user, %{}, hash_password: false)

    github_connected = Integrations.connected?(scope, :github)
    google_connected = Integrations.connected?(scope, :google)

    socket =
      socket
      |> assign(:current_email, user.email)
      |> assign(:email_form, to_form(email_changeset))
      |> assign(:password_form, to_form(password_changeset))
      |> assign(:trigger_submit, false)
      |> assign(:github_connected, github_connected)
      |> assign(:google_connected, google_connected)

    {:ok, socket}
  end

  def handle_event("validate_email", params, socket) do
    %{"user" => user_params} = params

    email_form =
      socket.assigns.current_scope.user
      |> Users.change_user_email(user_params, validate_unique: false)
      |> Map.put(:action, :validate)
      |> to_form()

    {:noreply, assign(socket, email_form: email_form)}
  end

  def handle_event("update_email", params, socket) do
    %{"user" => user_params} = params
    user = socket.assigns.current_scope.user
    true = Users.sudo_mode?(user)

    case Users.change_user_email(user, user_params) do
      %{valid?: true} = changeset ->
        Users.deliver_user_update_email_instructions(
          Ecto.Changeset.apply_action!(changeset, :insert),
          user.email,
          &url(socket, ~p"/app/users/settings/confirm-email/#{&1}")
        )

        info = "A link to confirm your email change has been sent to the new address."
        {:noreply, socket |> put_flash(:info, info)}

      changeset ->
        {:noreply, assign(socket, :email_form, to_form(changeset, action: :insert))}
    end
  end

  def handle_event("validate_password", params, socket) do
    %{"user" => user_params} = params

    password_form =
      socket.assigns.current_scope.user
      |> Users.change_user_password(user_params, hash_password: false)
      |> Map.put(:action, :validate)
      |> to_form()

    {:noreply, assign(socket, password_form: password_form)}
  end

  def handle_event("update_password", params, socket) do
    %{"user" => user_params} = params
    user = socket.assigns.current_scope.user
    true = Users.sudo_mode?(user)

    case Users.change_user_password(user, user_params) do
      %{valid?: true} = changeset ->
        {:noreply, assign(socket, trigger_submit: true, password_form: to_form(changeset))}

      changeset ->
        {:noreply, assign(socket, password_form: to_form(changeset, action: :insert))}
    end
  end
end
