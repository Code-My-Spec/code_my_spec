defmodule CodeMySpecWeb.UserLive.CheckEmail do
  use CodeMySpecWeb, :live_view

  alias CodeMySpec.Users

  @cooldown_seconds 60

  def render(assigns) do
    ~H"""
    <Layouts.marketing flash={@flash} current_scope={@current_scope}>
      <div
        id="check-email-page"
        phx-hook=".RegistrationEmailSent"
        class="mx-auto max-w-sm text-center space-y-6"
      >
        <.header>Check your email</.header>

        <p class="text-base-content/80">
          We sent a login link to <strong>{@email}</strong>. Click it to confirm your account.
        </p>

        <p class="text-sm text-base-content/60">
          Didn't get it? Check your spam folder, or
          <button
            type="button"
            id="resend-button"
            phx-click="resend"
            disabled={@cooldown_remaining > 0}
            class="font-semibold text-brand hover:underline disabled:opacity-50 disabled:no-underline"
          >
            <%= if @cooldown_remaining > 0 do %>
              Resend ({@cooldown_remaining}s)
            <% else %>
              resend the link
            <% end %>
          </button>
        </p>

        <p class="text-sm">
          <.link navigate={~p"/users/register"} class="text-base-content/60 hover:underline">
            Wrong email?
          </.link>
        </p>
      </div>

      <script :type={Phoenix.LiveView.ColocatedHook} name=".RegistrationEmailSent">
        export default {
          mounted() {
            if (typeof gtag === "function") {
              gtag("event", "registration_email_sent");
            }
          }
        }
      </script>
    </Layouts.marketing>
    """
  end

  def mount(%{"email" => email}, _session, socket) when is_binary(email) and email != "" do
    {:ok, assign(socket, email: email, cooldown_remaining: 0)}
  end

  def mount(_params, _session, socket) do
    {:ok, push_navigate(socket, to: ~p"/users/register")}
  end

  def handle_event("resend", _params, socket) do
    %{email: email, cooldown_remaining: remaining} = socket.assigns

    if remaining > 0 do
      {:noreply, socket}
    else
      if user = Users.get_user_by_email(email) do
        Users.deliver_login_instructions(user, &url(~p"/users/log-in/#{&1}"))
      end

      if connected?(socket), do: Process.send_after(self(), :tick, 1000)
      {:noreply, assign(socket, :cooldown_remaining, @cooldown_seconds)}
    end
  end

  def handle_info(:tick, socket) do
    remaining = max(socket.assigns.cooldown_remaining - 1, 0)
    if remaining > 0 and connected?(socket), do: Process.send_after(self(), :tick, 1000)
    {:noreply, assign(socket, :cooldown_remaining, remaining)}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}
end
