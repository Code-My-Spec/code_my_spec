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
        class="mx-auto grid w-full max-w-7xl grid-cols-1 items-start gap-12 px-6 py-20 lg:grid-cols-[1.05fr_1fr] lg:gap-16 lg:py-28"
      >
        <%!-- LEFT — platform positioning + proof --%>
        <section class="order-2 lg:order-1">
          <span class="badge badge-primary badge-outline mb-6">Get started</span>

          <h1 class="text-3xl font-bold tracking-tight text-base-content text-balance lg:text-4xl xl:text-5xl">
            Bring the idea. <span class="text-primary">Start building.</span>
          </h1>

          <p class="mt-6 max-w-[48ch] text-lg leading-snug text-base-content/70">
            Free to build — you and the model, shaping real software together. When it's ready for customers, the tools to run and grow it are right here.
          </p>

          <ul class="mt-9 flex flex-col gap-4 text-base-content">
            <li class="flex items-start gap-3">
              <.icon name="hero-check-circle" class="mt-0.5 size-5 flex-shrink-0 text-primary" />
              <span>
                Real software, not a prototype.
                <span class="text-base-content/60">
                  An app your customers actually log into — built with the model, with you calling the shots.
                </span>
              </span>
            </li>
            <li class="flex items-start gap-3">
              <.icon name="hero-check-circle" class="mt-0.5 size-5 flex-shrink-0 text-primary" />
              <span>
                Free to start, just an email.
                <span class="text-base-content/60">
                  No password, no company, no credit card. Bring your own AI keys; we never mark them up.
                </span>
              </span>
            </li>
            <li class="flex items-start gap-3">
              <.icon name="hero-check-circle" class="mt-0.5 size-5 flex-shrink-0 text-primary" />
              <span>
                Run and grow it when you're ready.
                <span class="text-base-content/60">
                  Email on your domain, live chat, content, and ads — one simple $100/mo plan.
                </span>
              </span>
            </li>
          </ul>

          <div class="mt-12 rounded-box border border-base-300 bg-base-100 px-5 py-4 text-sm leading-relaxed text-base-content/70">
            <span class="mb-1 block font-semibold text-primary">Proof</span>
            John built and runs MetricFlow — and this whole company — on CodeMySpec.
            <.link
              navigate={~p"/case-studies/metric-flow"}
              class="link link-primary font-medium"
            >
              Read the case study
            </.link>
          </div>
        </section>

        <%!-- RIGHT — auth block --%>
        <aside class="order-1 lg:order-2 lg:sticky lg:top-16">
          <div class="card border border-base-300 bg-base-100 shadow-sm">
            <div class="card-body gap-0 p-7 sm:p-9">
              <div class="mb-2 flex items-center justify-between">
                <span class="text-sm font-semibold text-base-content">Create account</span>
                <span class="badge badge-primary badge-sm">Free · no credit card</span>
              </div>

              <h2 class="mb-6 text-2xl font-bold tracking-tight text-base-content">
                Get started.
              </h2>

              <%!-- OAuth — primary path. --%>
              <div class="flex flex-col gap-3">
                <.link
                  href={~p"/auth/github/login"}
                  data-registration-method="github"
                  class="btn btn-primary w-full gap-3"
                >
                  <svg class="size-5" viewBox="0 0 24 24" fill="currentColor" aria-hidden="true">
                    <path d="M12 0C5.37 0 0 5.37 0 12c0 5.31 3.435 9.795 8.205 11.385.6.105.825-.255.825-.57 0-.285-.015-1.23-.015-2.235-3.015.555-3.795-.735-4.035-1.41-.135-.345-.72-1.41-1.23-1.695-.42-.225-1.02-.78-.015-.795.945-.015 1.62.87 1.845 1.23 1.08 1.815 2.805 1.305 3.495.99.105-.78.42-1.305.765-1.605-2.67-.3-5.46-1.335-5.46-5.925 0-1.305.465-2.385 1.23-3.225-.12-.3-.54-1.53.12-3.18 0 0 1.005-.315 3.3 1.23.96-.27 1.98-.405 3-.405s2.04.135 3 .405c2.295-1.56 3.3-1.23 3.3-1.23.66 1.65.24 2.88.12 3.18.765.84 1.23 1.905 1.23 3.225 0 4.605-2.805 5.625-5.475 5.925.435.375.81 1.095.81 2.22 0 1.605-.015 2.895-.015 3.3 0 .315.225.69.825.57A12.02 12.02 0 0 0 24 12c0-6.63-5.37-12-12-12z" />
                  </svg>
                  <span>Continue with GitHub</span>
                  <span class="badge badge-sm ml-auto border-none bg-primary-content text-primary">
                    Fast
                  </span>
                </.link>

                <.link
                  href={~p"/auth/google/login"}
                  data-registration-method="google"
                  class="btn btn-outline w-full gap-3"
                >
                  <svg class="size-5" viewBox="0 0 24 24" aria-hidden="true">
                    <path
                      d="M22.56 12.25c0-.78-.07-1.53-.2-2.25H12v4.26h5.92a5.06 5.06 0 0 1-2.2 3.32v2.77h3.57c2.08-1.92 3.28-4.74 3.28-8.1z"
                      fill="#4285F4"
                    />
                    <path
                      d="M12 23c2.97 0 5.46-.98 7.28-2.66l-3.57-2.77c-.98.66-2.23 1.06-3.71 1.06-2.86 0-5.29-1.93-6.16-4.53H2.18v2.84C3.99 20.53 7.7 23 12 23z"
                      fill="#34A853"
                    />
                    <path
                      d="M5.84 14.09c-.22-.66-.35-1.36-.35-2.09s.13-1.43.35-2.09V7.07H2.18A10.96 10.96 0 0 0 1 12c0 1.77.42 3.45 1.18 4.93l2.85-2.22.81-.62z"
                      fill="#FBBC05"
                    />
                    <path
                      d="M12 5.38c1.62 0 3.06.56 4.21 1.64l3.15-3.15C17.45 2.09 14.97 1 12 1 7.7 1 3.99 3.47 2.18 7.07l3.66 2.84c.87-2.6 3.3-4.53 6.16-4.53z"
                      fill="#EA4335"
                    />
                  </svg>
                  <span>Continue with Google</span>
                </.link>
              </div>

              <%!-- divider --%>
              <div class="divider text-xs text-base-content/50">or magic link</div>

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
                  class="input input-bordered w-full"
                />

                <.button
                  phx-disable-with="Sending login link..."
                  class="btn btn-secondary btn-outline mt-3 w-full"
                >
                  Email me a login link
                </.button>
              </.form>

              <div class="mt-5 border-t border-base-300 pt-4 text-center text-sm text-base-content/60">
                Already have an account?
                <.link navigate={~p"/users/log-in"} class="link link-primary font-medium">
                  Log in
                </.link>
              </div>
            </div>
          </div>
        </aside>
      </div>

      <script :type={Phoenix.LiveView.ColocatedHook} name=".ViewRegisterPage">
        // Hybrid analytics: behavior events fire via gtag directly.
        // view_register_page fires on mount; form/oauth interaction
        // events fire on user action. No server round-trip needed —
        // gtag handles sessions, engagement, and attribution natively.
        export default {
          mounted() {
            if (typeof gtag === "function") {
              gtag('event', 'view_register_page');
            }

            const emailField = this.el.querySelector('input[type="email"]');
            if (emailField) {
              emailField.addEventListener("focus", () => {
                if (typeof gtag === "function") {
                  gtag('event', 'registration_form_start', { method: "email" });
                  gtag('event', 'registration_path_chosen', { method: "email" });
                }
              }, { once: true });
            }

            const form = this.el.querySelector('#registration_form');
            if (form) {
              form.addEventListener("submit", () => {
                if (typeof gtag === "function") {
                  gtag('event', 'registration_path_chosen', { method: "email" });
                }
              }, { once: true });
            }

            this.el.querySelectorAll('[data-registration-method]').forEach((link) => {
              link.addEventListener("click", () => {
                const method = link.dataset.registrationMethod;
                if (typeof gtag === "function") {
                  gtag('event', 'registration_path_chosen', { method: method });
                  gtag('event', 'oauth_' + method + '_clicked');
                }
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

  def mount(_params, session, socket) do
    changeset = Users.change_user_email(%User{})

    # view_register_page fires browser-side via the .ViewRegisterPage gtag hook.
    # Read the gtag stitch ids (client_id + session_id) from the session
    # (written by GaClientId plug) so the sign_up + registration_email_sent MP
    # conversions stitch to the browser's GA4 session (rule f9b2c751).
    {:ok,
     socket
     |> assign(:page_title, "Get Started Free — CodeMySpec")
     |> assign(
       :meta_description,
       "Create a free CodeMySpec account with just an email. Build real software with the model, bring your own AI keys, own everything you make."
     )
     |> assign(:canonical_url, "#{CodeMySpecWeb.Endpoint.url()}/users/register")
     |> assign(:ga_client_id, Map.get(session, "ga_client_id"))
     |> assign(:ga_session_id, Map.get(session, "ga_session_id"))
     |> assign_form(changeset), temporary_assigns: [form: nil]}
  end

  def handle_event("save", %{"user" => user_params}, socket) do
    # Thread the gtag stitch ids (read at mount) into both conversion
    # dispatches so they stitch to the browser's GA4 session without
    # Process-dict side channels.
    ga_opts = ga_stitch_opts(socket)

    case Users.register_user(user_params, ga_opts) do
      {:ok, user} ->
        # Pass the socket so the URL resolves against the request's
        # actual host (e.g. http://localhost:4000 in dev) instead of
        # the endpoint's configured production URL.
        {:ok, _} =
          Users.deliver_login_instructions(
            user,
            &url(socket, ~p"/users/log-in/#{&1}")
          )

        CodeMySpec.Analytics.dispatch(
          :registration_email_sent,
          Enum.into(ga_opts, %{user_id: user.id})
        )

        {:noreply, push_navigate(socket, to: ~p"/users/check-email?email=#{user.email}")}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign_form(socket, changeset)}
    end
  end

  def handle_event("validate", %{"user" => user_params}, socket) do
    changeset = Users.change_user_email(%User{}, user_params)
    {:noreply, assign_form(socket, Map.put(changeset, :action, :validate))}
  end

  # gtag stitch ids as dispatch opts, dropping any that weren't on the _ga cookies.
  defp ga_stitch_opts(socket) do
    [
      ga_client_id: socket.assigns[:ga_client_id],
      ga_session_id: socket.assigns[:ga_session_id]
    ]
    |> Enum.reject(fn {_k, v} -> is_nil(v) or v == "" end)
  end

  defp assign_form(socket, %Ecto.Changeset{} = changeset) do
    form = to_form(changeset, as: "user")
    assign(socket, form: form)
  end
end
