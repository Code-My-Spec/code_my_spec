defmodule CodeMySpecWeb.UserLive.Registration do
  use CodeMySpecWeb, :live_view

  alias CodeMySpec.Users
  alias CodeMySpec.Users.User

  def render(assigns) do
    ~H"""
    <Layouts.marketing flash={@flash} current_scope={@current_scope}>
      <div
        id="register-page"
        phx-hook=".ViewRegisterPage"
        class="brand-zone mx-auto grid w-full max-w-7xl grid-cols-1 items-start gap-12 px-6 py-20 lg:grid-cols-[1.05fr_1fr] lg:gap-16 lg:py-28"
      >
        <%!-- LEFT — platform positioning + proof --%>
        <section class="order-2 lg:order-1">
          <div class="mb-7 flex items-center gap-3 font-mono text-[11px] uppercase tracking-[0.22em] text-primary">
            <span class="text-base-content/40">00</span>
            <span>// register</span>
            <span class="ml-2 hidden h-px max-w-[200px] flex-1 bg-gradient-to-r from-primary to-transparent sm:block"></span>
          </div>

          <h1 class="font-display text-4xl font-bold uppercase leading-[1.02] tracking-tight text-base-content text-balance lg:text-5xl xl:text-[56px]">
            If your AI-generated codebase is starting to
            <span class="bg-primary/15 px-1">slip</span>,
            this is the <span class="text-primary">harness</span> that holds it together.
          </h1>

          <p class="mt-6 max-w-[48ch] text-[17px] leading-snug text-base-content/70">
            A Claude Code plugin platform. One harness per domain. Bring your own Claude. Bring your own keys. We don't markup tokens.
          </p>

          <ul class="mt-9 flex flex-col gap-3.5 font-mono text-[13px] text-base-content">
            <li class="flex items-start gap-3.5">
              <span class="w-4 flex-shrink-0 font-bold text-primary">▸</span>
              <span>
                Architecture stays clean as AI volume goes up.
                <em class="not-italic text-base-content/60">
                  Specs, contexts, decisions — the boundaries the harness enforces.
                </em>
              </span>
            </li>
            <li class="flex items-start gap-3.5">
              <span class="w-4 flex-shrink-0 font-bold text-primary">▸</span>
              <span>
                Passwordless from day one.
                <em class="not-italic text-base-content/60">
                  No password, no name, no company. Just an email.
                </em>
              </span>
            </li>
            <li class="flex items-start gap-3.5">
              <span class="w-4 flex-shrink-0 font-bold text-primary">▸</span>
              <span>Built in the open, in the order I needed them.</span>
            </li>
          </ul>

          <div class="chamfer-md mt-12 border border-primary/20 bg-base-300/40 px-5 py-4 font-mono text-[12px] leading-relaxed text-base-content/70">
            <span class="mb-1 block text-[10px] uppercase tracking-[0.22em] text-primary">
              // proof
            </span>
            John shipped MetricFlow using these harnesses.
            <.link
              navigate={~p"/case-studies/metric-flow"}
              class="text-base-content underline decoration-primary/60 underline-offset-4 hover:text-primary hover:decoration-primary"
            >
              Read the case study →
            </.link>
          </div>
        </section>

        <%!-- RIGHT — auth block --%>
        <aside class="order-1 lg:order-2 lg:sticky lg:top-16">
          <div class="chamfer-lg relative border border-primary/20 bg-base-200 p-7 sm:p-9">
            <div class="absolute left-4 right-0 top-0 h-0.5 bg-primary shadow-[0_0_12px_#ff3838]">
            </div>

            <div class="mb-1.5 flex items-center justify-between font-mono text-[10px] uppercase tracking-[0.24em] text-base-content/40">
              <span>// create_account</span>
              <span class="text-primary">FREE · NO CREDIT CARD</span>
            </div>

            <h2 class="mb-6 font-display text-[22px] font-bold uppercase tracking-tight text-base-content">
              Get started.
            </h2>

            <%!-- OAuth — primary path. .brand-zone .btn-primary applies chamfer + mono + white-on-hover. --%>
            <div class="flex flex-col gap-2.5">
              <.link
                href={~p"/auth/github/login"}
                data-registration-method="github"
                class="btn btn-primary flex min-h-[52px] w-full items-center justify-center gap-3 shadow-[0_0_24px_rgba(255,56,56,0.25)]"
              >
                <svg class="size-5" viewBox="0 0 24 24" fill="currentColor" aria-hidden="true">
                  <path d="M12 0C5.37 0 0 5.37 0 12c0 5.31 3.435 9.795 8.205 11.385.6.105.825-.255.825-.57 0-.285-.015-1.23-.015-2.235-3.015.555-3.795-.735-4.035-1.41-.135-.345-.72-1.41-1.23-1.695-.42-.225-1.02-.78-.015-.795.945-.015 1.62.87 1.845 1.23 1.08 1.815 2.805 1.305 3.495.99.105-.78.42-1.305.765-1.605-2.67-.3-5.46-1.335-5.46-5.925 0-1.305.465-2.385 1.23-3.225-.12-.3-.54-1.53.12-3.18 0 0 1.005-.315 3.3 1.23.96-.27 1.98-.405 3-.405s2.04.135 3 .405c2.295-1.56 3.3-1.23 3.3-1.23.66 1.65.24 2.88.12 3.18.765.84 1.23 1.905 1.23 3.225 0 4.605-2.805 5.625-5.475 5.925.435.375.81 1.095.81 2.22 0 1.605-.015 2.895-.015 3.3 0 .315.225.69.825.57A12.02 12.02 0 0 0 24 12c0-6.63-5.37-12-12-12z" />
                </svg>
                <span>Continue with GitHub</span>
                <span class="chamfer-sm ml-auto bg-primary-content px-2 py-1 font-mono text-[9px] tracking-[0.2em] text-primary">
                  FAST
                </span>
              </.link>

              <.link
                href={~p"/auth/google/login"}
                data-registration-method="google"
                class="chamfer-sm flex min-h-[52px] w-full items-center justify-center gap-3 border-[1.5px] border-primary/20 bg-transparent font-mono text-[13px] font-semibold uppercase tracking-[0.12em] text-base-content transition-colors hover:border-primary hover:bg-primary/5"
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
            <div class="my-5 flex items-center gap-3.5 font-mono text-[10px] uppercase tracking-[0.24em] text-base-content/40">
              <span class="h-px flex-1 bg-primary/20"></span>
              <span>or magic link</span>
              <span class="h-px flex-1 bg-primary/20"></span>
            </div>

            <%!-- email magic link --%>
            <.form for={@form} id="registration_form" phx-submit="save" phx-change="validate">
              <.input
                field={@form[:email]}
                type="email"
                label="Email"
                placeholder="you@domain.dev"
                autocomplete="username"
                required
                phx-mounted={JS.focus()}
                class="chamfer-sm input min-h-[52px] w-full border-[1.5px] border-primary/20 bg-base-100 font-mono text-[14px] text-base-content focus:border-primary focus:shadow-[0_0_0_3px_rgba(255,56,56,0.15)] focus:outline-none"
              />

              <.button
                phx-disable-with="Sending login link..."
                class="chamfer-sm mt-3 flex min-h-[52px] w-full items-center justify-center gap-2.5 border-[1.5px] border-primary bg-transparent font-mono text-[13px] font-semibold uppercase tracking-[0.14em] text-primary transition-colors hover:bg-primary hover:text-primary-content"
              >
                <span class="font-mono">▸</span> Email me a login link
              </.button>
            </.form>

            <div class="mt-5 border-t border-primary/10 pt-4 text-center font-mono text-[11px] leading-relaxed text-base-content/40">
              Already have an account?
              <.link
                navigate={~p"/users/log-in"}
                class="text-base-content underline decoration-primary/60 underline-offset-4 hover:text-primary hover:decoration-primary"
              >
                Log in →
              </.link>
            </div>
          </div>
        </aside>
      </div>

      <script :type={Phoenix.LiveView.ColocatedHook} name=".ViewRegisterPage">
        export default {
          mounted() {
            const track = (event, params) => {
              if (typeof gtag === "function") {
                gtag("event", event, params || {});
              }
            };

            track("view_register_page");

            const emailField = this.el.querySelector('input[type="email"]');
            if (emailField) {
              emailField.addEventListener("focus", () => {
                track("registration_form_start", { method: "email" });
                track("registration_path_chosen", { method: "email" });
              }, { once: true });
            }

            const form = this.el.querySelector('#registration_form');
            if (form) {
              form.addEventListener("submit", () => {
                track("registration_path_chosen", { method: "email" });
              }, { once: true });
            }

            this.el.querySelectorAll('[data-registration-method]').forEach((link) => {
              link.addEventListener("click", () => {
                const method = link.dataset.registrationMethod;
                track("registration_path_chosen", { method: method });
                track("oauth_" + method + "_clicked");
              }, { once: true });
            });
          }
        }
      </script>
    </Layouts.marketing>
    """
  end

  def mount(_params, _session, %{assigns: %{current_scope: %{user: user}}} = socket)
      when not is_nil(user) do
    {:ok, redirect(socket, to: CodeMySpecWeb.UserAuth.signed_in_path(socket))}
  end

  def mount(_params, _session, socket) do
    changeset = Users.change_user_email(%User{})

    {:ok, assign_form(socket, changeset), temporary_assigns: [form: nil]}
  end

  def handle_event("save", %{"user" => user_params}, socket) do
    case Users.register_user(user_params) do
      {:ok, user} ->
        # Pass the socket so the URL resolves against the request's
        # actual host (e.g. http://localhost:4000 in dev) instead of
        # the endpoint's configured production URL.
        {:ok, _} =
          Users.deliver_login_instructions(
            user,
            &url(socket, ~p"/users/log-in/#{&1}")
          )

        CodeMySpec.Analytics.dispatch(:registration_email_sent, %{user_id: user.id})

        {:noreply, push_navigate(socket, to: ~p"/users/check-email?email=#{user.email}")}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign_form(socket, changeset)}
    end
  end

  def handle_event("validate", %{"user" => user_params}, socket) do
    changeset = Users.change_user_email(%User{}, user_params)
    {:noreply, assign_form(socket, Map.put(changeset, :action, :validate))}
  end

  defp assign_form(socket, %Ecto.Changeset{} = changeset) do
    form = to_form(changeset, as: "user")
    assign(socket, form: form)
  end
end
