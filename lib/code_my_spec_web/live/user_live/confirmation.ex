defmodule CodeMySpecWeb.UserLive.Confirmation do
  use CodeMySpecWeb, :live_view

  alias CodeMySpec.Users
  alias CodeMySpec.Users.Scope
  alias CodeMySpec.Accounts
  alias CodeMySpec.Accounts.Account

  def render(assigns) do
    ~H"""
    <Layouts.marketing flash={@flash} current_scope={@current_scope}>
      <div
        id="confirmation-page"
        phx-hook=".SignUpTracking"
        data-first-confirmation={to_string(!@user.confirmed_at)}
        class="mx-auto max-w-sm"
      >
        <div class="text-center">
          <.header>Welcome {@user.email}</.header>
        </div>

        <.form
          :if={!@user.confirmed_at}
          for={@form}
          id="confirmation_form"
          phx-mounted={JS.focus_first()}
          phx-submit="submit"
          action={~p"/users/log-in?_action=confirmed"}
          phx-trigger-action={@trigger_submit}
        >
          <input type="hidden" name={@form[:token].name} value={@form[:token].value} />
          <.button
            name={@form[:remember_me].name}
            value="true"
            phx-disable-with="Confirming..."
            class="btn btn-primary w-full"
          >
            Confirm and stay logged in
          </.button>
          <.button phx-disable-with="Confirming..." class="btn btn-primary btn-soft w-full mt-2">
            Confirm and log in only this time
          </.button>
        </.form>

        <.form
          :if={@user.confirmed_at}
          for={@form}
          id="login_form"
          phx-submit="submit"
          phx-mounted={JS.focus_first()}
          action={~p"/users/log-in"}
          phx-trigger-action={@trigger_submit}
        >
          <input type="hidden" name={@form[:token].name} value={@form[:token].value} />
          <%= if @current_scope do %>
            <.button phx-disable-with="Logging in..." class="btn btn-primary w-full">
              Log in
            </.button>
          <% else %>
            <.button
              name={@form[:remember_me].name}
              value="true"
              phx-disable-with="Logging in..."
              class="btn btn-primary w-full"
            >
              Keep me logged in on this device
            </.button>
            <.button phx-disable-with="Logging in..." class="btn btn-primary btn-soft w-full mt-2">
              Log me in only this time
            </.button>
          <% end %>
        </.form>

        <p :if={!@user.confirmed_at} class="alert alert-outline mt-8">
          Tip: If you prefer passwords, you can enable them in the user settings.
        </p>
      </div>

      <script :type={Phoenix.LiveView.ColocatedHook} name=".SignUpTracking">
        export default {
          mounted() {
            if (this.el.dataset.firstConfirmation === "true" && typeof gtag === "function") {
              gtag("event", "sign_up");
            }
          }
        }
      </script>
    </Layouts.marketing>
    """
  end

  def mount(%{"token" => token}, _session, socket) do
    if user = Users.get_user_by_magic_link_token(token) do
      form = to_form(%{"token" => token}, as: "user")

      {:ok, assign(socket, user: user, form: form, trigger_submit: false),
       temporary_assigns: [form: nil]}
    else
      {:ok,
       socket
       |> put_flash(:error, "Magic link is invalid or it has expired.")
       |> push_navigate(to: ~p"/users/log-in")}
    end
  end

  def handle_event("submit", %{"user" => params}, socket) do
    scope = Map.put(%Scope{}, :user, socket.assigns.user)
    %Account{} = Accounts.ensure_personal_account(scope)
    {:noreply, assign(socket, form: to_form(params, as: "user"), trigger_submit: true)}
  end
end
