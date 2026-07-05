defmodule CodeMySpecWeb.UserLive.CheckEmail do
  use CodeMySpecWeb, :live_view

  alias CodeMySpec.Users

  @cooldown_seconds 60

  def render(assigns) do
    ~H"""
    <Layouts.marketing flash={@flash} current_scope={@current_scope}>
      <div
        id="check-email-page"
        class="mx-auto max-w-xl py-12 flex flex-col gap-5"
      >
        <%!--
          Audit P1 #3: previously a bare centered paragraph, this screen now
          mirrors the sign-up card aesthetic and previews the four ladder
          steps the user will reach after clicking the magic link.
        --%>
        <div class="card border border-base-300 bg-base-100 shadow-sm">
          <div class="card-body gap-3 p-7">
            <span class="badge badge-primary badge-outline">Step 01 · confirm email</span>
            <h1 class="text-2xl font-bold tracking-tight text-base-content">Check your email.</h1>
            <p class="text-base-content/70">
              We sent a login link to <strong class="text-base-content">{@email}</strong>. Click it to confirm your account.
            </p>

            <div class="mt-2 flex flex-wrap items-center gap-3 text-sm text-base-content/60">
              <span>Didn't get it?</span>
              <button
                type="button"
                id="resend-button"
                phx-click="resend"
                disabled={@cooldown_remaining > 0}
                class="link link-primary font-medium disabled:opacity-50 disabled:cursor-not-allowed disabled:no-underline"
              >
                <%= if @cooldown_remaining > 0 do %>
                  Resend · {@cooldown_remaining}s
                <% else %>
                  Resend link
                <% end %>
              </button>
              <.link navigate={~p"/users/register"} class="link link-hover">
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
          <div class="flex items-center gap-3 px-1 text-sm font-medium text-base-content/60">
            <span>Next · 4 steps</span>
            <span class="h-px max-w-[120px] flex-1 bg-base-content/15"></span>
          </div>
          <.next_step n="02" label="Name your account" />
          <.next_step n="03" label="Name your first Phoenix project" />
          <.next_step n="04" label="Install the Claude Code plugin" />
          <.next_step n="05" label="Open the local workspace" />
        </div>
      </div>

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
    <div class="card border border-base-300 bg-base-200 opacity-60">
      <div class="flex items-center gap-4 px-6 py-4">
        <span class="badge badge-ghost badge-sm">Step {@n}</span>
        <span class="flex-1"></span>
        <span class="text-sm text-base-content/70">{@label}</span>
      </div>
    </div>
    """
  end
end
