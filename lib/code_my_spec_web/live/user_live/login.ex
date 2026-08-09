defmodule CodeMySpecWeb.UserLive.Login do
  use CodeMySpecWeb, :live_view

  alias CodeMySpec.Users

  def render(assigns) do
    ~H"""
    <Layouts.marketing current_path={assigns[:current_path]} flash={@flash} current_scope={@current_scope}>
      <div
        id="login-page"
        class={[
          "mx-auto w-full max-w-7xl px-6 py-20 lg:py-28",
          if(@current_scope,
            do: "max-w-md",
            else: "grid grid-cols-1 items-start gap-12 lg:grid-cols-[1.05fr_1fr] lg:gap-16"
          )
        ]}
      >
        <%!-- LEFT — positioning reminder; only shown when not in re-auth.
              Mirrors the register-page grid so /users/log-in stops floating
              as an orphaned card (CRO regression fix 2026-05-20). --%>
        <section :if={!@current_scope} class="order-2 lg:order-1">
          <span class="badge badge-primary badge-outline mb-6">Welcome back</span>

          <h1 class="text-3xl font-bold tracking-tight text-base-content text-balance lg:text-4xl xl:text-5xl">
            Welcome <span class="text-primary">back</span>.
          </h1>

          <p class="mt-6 max-w-[48ch] text-lg leading-snug text-base-content/70">
            Your work is right where you left it. Pick up building, running, and growing your software.
          </p>

          <ul class="mt-9 flex flex-col gap-4 text-base-content">
            <li class="flex items-start gap-3">
              <.icon name="hero-check-circle" class="mt-0.5 size-5 flex-shrink-0 text-primary" />
              <span>
                Bring your own AI keys.
                <span class="text-base-content/60">
                  No token markup. Ever.
                </span>
              </span>
            </li>
            <li class="flex items-start gap-3">
              <.icon name="hero-check-circle" class="mt-0.5 size-5 flex-shrink-0 text-primary" />
              <span>
                Passwordless from day one.
                <span class="text-base-content/60">
                  Magic link or OAuth. No password to remember.
                </span>
              </span>
            </li>
            <li class="flex items-start gap-3">
              <.icon name="hero-check-circle" class="mt-0.5 size-5 flex-shrink-0 text-primary" />
              <span>
                Everything in one place.
                <span class="text-base-content/60">
                  Your app, inbox, chat, content, and ads — one login.
                </span>
              </span>
            </li>
          </ul>
        </section>

        <%!-- RIGHT — auth card. OAuth-primary; magic-link secondary. --%>
        <aside class={[
          if(@current_scope, do: "", else: "order-1 lg:order-2 lg:sticky lg:top-16")
        ]}>
          <div class="card border border-base-300 bg-base-100 shadow-sm">
            <div class="card-body gap-0 p-7 sm:p-9">
              <div class="mb-2 flex items-center justify-between">
                <span class="text-sm font-semibold text-base-content">Log in</span>
                <span class="badge badge-primary badge-sm">Free · BYO keys</span>
              </div>

              <h2 class="mb-2 text-2xl font-bold tracking-tight text-base-content">
                Log in.
              </h2>

              <p class="mb-6 text-sm leading-relaxed text-base-content/60">
                <%= if @current_scope do %>
                  You need to reauthenticate to perform sensitive actions.
                <% else %>
                  Don't have an account?
                  <.link navigate={~p"/users/register"} class="link link-primary font-medium">
                    Get started
                  </.link>
                <% end %>
              </p>

              <div :if={local_mail_adapter?()} class="alert alert-info mb-5">
                <.icon name="hero-information-circle" class="size-6 shrink-0" />
                <div>
                  <p>You are running the local mail adapter.</p>
                  <p>
                    To see sent emails, visit <.link href="/dev/mailbox" class="underline">the mailbox page</.link>.
                  </p>
                </div>
              </div>

              <%!-- OAuth — primary path. --%>
              <div class="flex flex-col gap-3">
                <.link
                  href={~p"/auth/github/login"}
                  data-login-method="github"
                  class="btn btn-primary w-full gap-3"
                >
                  <svg class="size-5" viewBox="0 0 24 24" fill="currentColor" aria-hidden="true">
                    <path d="M12 0C5.37 0 0 5.37 0 12c0 5.31 3.435 9.795 8.205 11.385.6.105.825-.255.825-.57 0-.285-.015-1.23-.015-2.235-3.015.555-3.795-.735-4.035-1.41-.135-.345-.72-1.41-1.23-1.695-.42-.225-1.02-.78-.015-.795.945-.015 1.62.87 1.845 1.23 1.08 1.815 2.805 1.305 3.495.99.105-.78.42-1.305.765-1.605-2.67-.3-5.46-1.335-5.46-5.925 0-1.305.465-2.385 1.23-3.225-.12-.3-.54-1.53.12-3.18 0 0 1.005-.315 3.3 1.23.96-.27 1.98-.405 3-.405s2.04.135 3 .405c2.295-1.56 3.3-1.23 3.3-1.23.66 1.65.24 2.88.12 3.18.765.84 1.23 1.905 1.23 3.225 0 4.605-2.805 5.625-5.475 5.925.435.375.81 1.095.81 2.22 0 1.605-.015 2.895-.015 3.3 0 .315.225.69.825.57A12.02 12.02 0 0 0 24 12c0-6.63-5.37-12-12-12z" />
                  </svg>
                  <span>Continue with GitHub</span>
                </.link>

                <.link
                  href={~p"/auth/google/login"}
                  data-login-method="google"
                  class="btn btn-outline w-full gap-3"
                >
                  <svg class="size-5" viewBox="0 0 24 24" aria-hidden="true">
                    <path d="M22.56 12.25c0-.78-.07-1.53-.2-2.25H12v4.26h5.92a5.06 5.06 0 0 1-2.2 3.32v2.77h3.57c2.08-1.92 3.28-4.74 3.28-8.1z" fill="#4285F4" />
                    <path d="M12 23c2.97 0 5.46-.98 7.28-2.66l-3.57-2.77c-.98.66-2.23 1.06-3.71 1.06-2.86 0-5.29-1.93-6.16-4.53H2.18v2.84C3.99 20.53 7.7 23 12 23z" fill="#34A853" />
                    <path d="M5.84 14.09c-.22-.66-.35-1.36-.35-2.09s.13-1.43.35-2.09V7.07H2.18A10.96 10.96 0 0 0 1 12c0 1.77.42 3.45 1.18 4.93l2.85-2.22.81-.62z" fill="#FBBC05" />
                    <path d="M12 5.38c1.62 0 3.06.56 4.21 1.64l3.15-3.15C17.45 2.09 14.97 1 12 1 7.7 1 3.99 3.47 2.18 7.07l3.66 2.84c.87-2.6 3.3-4.53 6.16-4.53z" fill="#EA4335" />
                  </svg>
                  <span>Continue with Google</span>
                </.link>
              </div>

              <%!-- divider --%>
              <div class="divider text-xs text-base-content/50">or send a login link</div>

              <%!-- magic-link form --%>
              <.form
                :let={f}
                for={@form}
                id="login_form_magic"
                action={~p"/users/log-in"}
                phx-submit="submit_magic"
              >
                <.input
                  readonly={!!@current_scope}
                  field={f[:email]}
                  type="email"
                  label="Email"
                  autocomplete="username"
                  required
                  phx-mounted={JS.focus()}
                  class="input input-bordered w-full"
                />
                <.button class="btn btn-secondary btn-outline mt-3 w-full">
                  Email me a login link
                </.button>
              </.form>
            </div>
          </div>
        </aside>
      </div>
    </Layouts.marketing>
    """
  end

  def mount(_params, _session, socket) do
    email =
      Phoenix.Flash.get(socket.assigns.flash, :email) ||
        get_in(socket.assigns, [:current_scope, Access.key(:user), Access.key(:email)])

    form = to_form(%{"email" => email}, as: "user")

    {:ok, assign(socket, form: form)}
  end

  def handle_event("submit_magic", %{"user" => %{"email" => email}}, socket) do
    if user = Users.get_user_by_email(email) do
      Users.deliver_login_instructions(
        user,
        &url(socket, ~p"/users/log-in/#{&1}")
      )
    end

    info =
      "If your email is in our system, you will receive instructions for logging in shortly."

    {:noreply,
     socket
     |> put_flash(:info, info)
     |> push_navigate(to: ~p"/users/log-in")}
  end

  defp local_mail_adapter? do
    Application.get_env(:code_my_spec, CodeMySpec.Mailer)[:adapter] == Swoosh.Adapters.Local
  end
end
