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
        class="mx-auto max-w-xl py-12 flex flex-col gap-5"
      >
        <%!--
          Audit P1 #3: previously a bare centered paragraph on black, this
          screen now mirrors the /app rung aesthetic — same eyebrow, same
          chamfered card, and a preview of the four ladder steps the user
          will reach after clicking the magic link.
        --%>
        <div class="cms-onboarding">
          <div class="px-7 py-7 flex flex-col gap-3">
            <div class="cms-onboarding-eyebrow">// step 01 · confirm email</div>
            <h1 class="cms-onboarding-heading">Check your email.</h1>
            <p class="cms-onboarding-sub">
              We sent a login link to <strong class="text-base-content">{@email}</strong>. Click it to confirm your account.
            </p>

            <div class="flex items-center gap-3 flex-wrap text-xs font-mono uppercase tracking-[0.14em] text-base-content/60 mt-2">
              <span>Didn't get it?</span>
              <button
                type="button"
                id="resend-button"
                phx-click="resend"
                disabled={@cooldown_remaining > 0}
                class="cms-onboarding-copy disabled:opacity-50 disabled:cursor-not-allowed"
              >
                <%= if @cooldown_remaining > 0 do %>
                  Resend · {@cooldown_remaining}s
                <% else %>
                  Resend link
                <% end %>
              </button>
              <.link navigate={~p"/users/register"} class="opacity-70 hover:opacity-100 underline">
                Wrong email?
              </.link>
            </div>
          </div>
        </div>

        <%!--
          Preview of what's waiting after the click — collapses the latency
          gap between "I clicked confirm" and "I see the workspace ladder".
        --%>
        <div class="flex flex-col gap-3">
          <div class="flex items-center gap-3 text-xs font-mono uppercase tracking-[0.18em] text-base-content/60 px-1">
            <span>// next · 4 steps</span>
            <span class="h-px flex-1 max-w-[120px] bg-base-content/15"></span>
          </div>
          <.next_step n="02" label="Name your account" />
          <.next_step n="03" label="Name your first Phoenix project" />
          <.next_step n="04" label="Install the Claude Code plugin" />
          <.next_step n="05" label="Open the local workspace" />
        </div>
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
        Users.deliver_login_instructions(user, &url(socket, ~p"/users/log-in/#{&1}"))
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

  attr :n, :string, required: true
  attr :label, :string, required: true

  defp next_step(assigns) do
    ~H"""
    <div class="cms-onboarding" style="opacity: 0.55;">
      <div class="flex items-center gap-4 px-6 py-4">
        <span class="cms-onboarding-eyebrow">// step {@n}</span>
        <span class="flex-1"></span>
        <span class="cms-onboarding-eyebrow" style="opacity: 0.7;">{@label}</span>
      </div>
    </div>
    """
  end
end
