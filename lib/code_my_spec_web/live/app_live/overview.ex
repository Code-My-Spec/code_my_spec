defmodule CodeMySpecWeb.AppLive.Overview do
  use CodeMySpecWeb, :live_view

  alias CodeMySpec.Accounts
  alias CodeMySpec.Accounts.Account
  alias CodeMySpec.Events
  alias CodeMySpec.Projects
  alias CodeMySpec.Projects.Project
  alias CodeMySpec.UserPreferences
  alias CodeMySpec.Users
  alias CodeMySpec.Users.Scope
  alias CodeMySpecWeb.CliChannel
  alias CodeMySpecWeb.Presence

  @install_steps [
    %{n: 1, command: "/plugin marketplace add Code-My-Spec/plugins"},
    %{n: 2, command: "/plugin install codemyspec@codemyspec"},
    %{n: 3, command: "/plugin-reload"}
  ]

  def mount(_params, _session, socket) do
    scope = socket.assigns.current_scope

    socket =
      socket
      |> assign(page_title: "Overview")
      |> assign_onboarding_state(scope.user)

    if connected?(socket) do
      Phoenix.PubSub.subscribe(CodeMySpec.PubSub, presence_topic(scope.user))
      Phoenix.PubSub.subscribe(CodeMySpec.PubSub, CliChannel.status_topic(scope.user.id))
    end

    case ensure_active_account(scope) do
      {:ok, scope} ->
        {:ok, assign_steps(socket, scope)}

      {:redirect, path} ->
        {:ok, push_navigate(socket, to: path)}
    end
  end

  defp ensure_active_account(scope) do
    cond do
      scope.active_account ->
        {:ok, scope}

      Accounts.list_accounts(scope) == [] ->
        {:ok, scope}

      true ->
        [first | _] = Accounts.list_accounts(scope)

        case UserPreferences.select_active_account(scope, first.id) do
          {:ok, _} -> {:ok, Scope.for_user(scope.user)}
          {:error, _} -> {:redirect, ~p"/app/accounts/picker"}
        end
    end
  end

  defp assign_steps(socket, scope) do
    state = build_step_state(scope)

    socket
    |> assign(:current_scope, scope)
    |> assign(state)
    |> assign_account_form()
    |> assign_project_form(scope)
  end

  defp build_step_state(scope) do
    account_done? = !is_nil(scope.active_account)
    projects = if account_done?, do: Projects.list_projects(scope), else: []
    project_done? = projects != []
    cli_ever_connected? = Users.cli_ever_connected?(scope.user)
    application_done? = Events.exists?("local_signed_in", user_id: scope.user.id)
    active_project = scope.active_project || List.first(projects)

    %{
      account_done?: account_done?,
      account_count: if(account_done?, do: 1, else: 0),
      account_name: account_done? && scope.active_account.name,
      project_done?: project_done?,
      project_count: length(projects),
      project_name: active_project && active_project.name,
      active_project_id: active_project && active_project.id,
      cli_ever_connected?: cli_ever_connected?,
      application_done?: application_done?,
      active_step:
        active_step(account_done?, project_done?, cli_ever_connected?, application_done?)
    }
  end

  # The active step is always the first incomplete one in the fixed
  # order. Once everything is done (including the user signing in to
  # the local app), there is no active step — every rung renders
  # "done" and the ladder is fully resolved.
  defp active_step(false, _, _, _), do: :account
  defp active_step(true, false, _, _), do: :project
  defp active_step(true, true, false, _), do: :plugin
  defp active_step(true, true, true, false), do: :application
  defp active_step(true, true, true, true), do: nil

  # A rung is "done" if its prerequisite has been fulfilled, "active"
  # if it's the current first-incomplete step, otherwise "pending".
  # The application rung flips to "done" once the local app has
  # recorded a `local_signed_in` activation event for this user.
  # Multi-clause dispatch keeps cyclomatic complexity flat — each
  # rung's done-condition matches a single arg position.
  defp rung_state(step, step, _, _, _, _), do: "active"
  defp rung_state(:account, _, true, _, _, _), do: "done"
  defp rung_state(:project, _, _, true, _, _), do: "done"
  defp rung_state(:plugin, _, _, _, true, _), do: "done"
  defp rung_state(:application, _, _, _, _, true), do: "done"
  defp rung_state(_, _, _, _, _, _), do: "pending"

  defp assign_account_form(socket) do
    if socket.assigns.account_done? do
      assign(socket, :account_form, nil)
    else
      form =
        %{}
        |> Account.create_changeset()
        |> to_form(as: "account")

      assign(socket, :account_form, form)
    end
  end

  defp assign_project_form(socket, scope) do
    if socket.assigns.project_done? do
      assign(socket, project_form: nil, project_module_preview: "")
    else
      form =
        %Project{}
        |> Project.changeset(%{}, scope)
        |> to_form(as: "project")

      assign(socket, project_form: form, project_module_preview: "")
    end
  end

  def handle_event("create_account", %{"account" => params}, socket) do
    scope = socket.assigns.current_scope

    case Accounts.create_account(scope, params) do
      {:ok, account} ->
        {:ok, _} = UserPreferences.select_active_account(scope, account.id)
        {:noreply, push_navigate(socket, to: ~p"/app")}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply,
         assign(socket,
           account_form:
             changeset |> surface_slug_errors_on_name() |> to_form(as: "account", action: :insert)
         )}
    end
  end

  def handle_event("validate_project", %{"project" => %{"name" => name}}, socket) do
    {:noreply, assign(socket, :project_module_preview, derive_module_name(name || ""))}
  end

  def handle_event("save_project", %{"project" => params}, socket) do
    scope = socket.assigns.current_scope

    attrs = Map.put(params, "module_name", derive_module_name(params["name"] || ""))

    case Projects.create_project(scope, attrs) do
      {:ok, project} ->
        {:ok, _} = UserPreferences.select_active_project(scope, project.id)
        {:noreply, push_navigate(socket, to: ~p"/app")}

      {:error, changeset} ->
        {:noreply, assign(socket, project_form: to_form(changeset, as: "project"))}
    end
  end

  # Server-driven toggle: flip the assign and let the re-render swap
  # collapse-open/collapse-close. Kept server-authoritative (rather than a
  # client-side JS.toggle_class) so frequent presence re-renders during CLI
  # connect can't race the class back open.
  def handle_event("toggle_onboarding", _params, socket) do
    {:noreply, assign(socket, onboarding_expanded: !socket.assigns.onboarding_expanded)}
  end

  def handle_event("copy_step", %{"step" => step_str}, socket) do
    case Integer.parse(step_str) do
      # step 0 == prereq (`mix phx.new`), steps 1..3 == plugin install commands.
      # install_step_copied fires browser-side via the .SignUpTracking gtag hook.
      {step, ""} when step in 0..3 ->
        {:noreply, push_event(socket, "install_step_copied", %{step: step})}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_info(%Phoenix.Socket.Broadcast{event: "presence_diff"}, socket) do
    {:noreply, refresh_presence(socket)}
  end

  def handle_info(:cli_presence_changed, socket) do
    {:noreply, refresh_presence(socket)}
  end

  # An activation milestone landed for this user — re-derive ladder
  # state so the rung that just unlocked flips in-place.
  def handle_info({:activation_event, _name, _payload}, socket) do
    state = build_step_state(socket.assigns.current_scope)
    {:noreply, assign(socket, state)}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  # The user only enters a `name`; `slug` is auto-derived from it. So
  # slug-level errors need to surface against the name field or they're
  # invisible. Uniqueness collisions are handled by the repository's
  # auto-suffix retry — by the time we see slug errors here they're
  # reserved words, length, or format violations of the derived slug.
  defp surface_slug_errors_on_name(changeset) do
    Enum.reduce(changeset.errors, changeset, fn
      {:slug, {msg, opts}}, cs ->
        Ecto.Changeset.add_error(cs, :name, slug_error_to_name_msg(msg), opts)

      _, cs ->
        cs
    end)
  end

  defp slug_error_to_name_msg("is reserved" <> _),
    do: "uses a reserved word — try a different name"

  defp slug_error_to_name_msg("should be at least " <> _),
    do: "needs at least 3 letters or numbers"

  defp slug_error_to_name_msg("must contain only" <> _),
    do: "needs at least one letter or number"

  defp slug_error_to_name_msg(_),
    do: "isn't valid — try a different name"

  defp refresh_presence(socket) do
    user = socket.assigns.current_scope.user
    count = current_session_count(user)

    socket
    |> assign(:cli_session_count, count)
    |> maybe_celebrate_first_connect(count)
  end

  defp maybe_celebrate_first_connect(socket, count) do
    cond do
      socket.assigns.show_celebrate ->
        socket

      count > 0 and is_nil(socket.assigns.cli_first_connected_at) ->
        user = Users.get_user!(socket.assigns.current_scope.user.id)

        socket
        |> assign(:cli_first_connected_at, user.cli_first_connected_at)
        |> assign(:cli_ever_connected?, true)
        |> assign(:show_celebrate, true)
        # Collapse the install panel on connect — installation is done, so
        # tuck it away (the "Open the local workspace" step below carries the
        # next action). Re-expandable to reinstall on another machine.
        |> assign(:onboarding_expanded, false)

      true ->
        socket
    end
  end

  defp assign_onboarding_state(socket, user) do
    count = if connected?(socket), do: current_session_count(user), else: 0
    ever_connected? = Users.cli_ever_connected?(user)

    socket
    |> assign(:cli_first_connected_at, user.cli_first_connected_at)
    |> assign(:cli_session_count, count)
    |> assign(:onboarding_expanded, not ever_connected?)
    |> assign(:show_celebrate, false)
    |> assign(:install_steps, @install_steps)
  end

  defp current_session_count(user) do
    presence_topic(user)
    |> Presence.list()
    |> map_size()
  end

  defp presence_topic(user), do: "cli:user:#{user.id}"

  defp derive_module_name(name) do
    derived =
      name
      |> String.replace(~r/[^A-Za-z0-9]/u, " ")
      |> String.split(~r/\s+/u, trim: true)
      |> Enum.map(&String.replace(&1, ~r/^\d+/, ""))
      |> Enum.reject(&(&1 == ""))
      |> Enum.map_join("", &capitalize_first/1)

    if derived == "", do: "Project" <> short_id(), else: derived
  end

  defp capitalize_first(""), do: ""

  defp capitalize_first(<<first::utf8, rest::binary>>) do
    <<String.upcase(<<first::utf8>>)::binary, rest::binary>>
  end

  defp short_id do
    :crypto.strong_rand_bytes(4) |> Base.encode16(case: :upper) |> String.slice(0, 6)
  end

  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div
        id="onboarding-page"
        phx-hook=".SignUpTracking"
      >
        <div class="mx-auto max-w-2xl flex flex-col gap-4">
          <.welcome_banner :if={!@account_done?} />

          <.ladder_progress
            account_done?={@account_done?}
            project_done?={@project_done?}
            cli_ever_connected?={@cli_ever_connected?}
            application_done?={@application_done?}
          />

          <.account_rung
            state={rung_state(:account, @active_step, @account_done?, @project_done?, @cli_ever_connected?, @application_done?)}
            count={@account_count}
            name={@account_name}
            account_form={@account_form}
          />

          <.project_rung
            state={rung_state(:project, @active_step, @account_done?, @project_done?, @cli_ever_connected?, @application_done?)}
            count={@project_count}
            name={@project_name}
            project_form={@project_form}
            project_module_preview={@project_module_preview}
          />

          <.plugin_rung
            state={rung_state(:plugin, @active_step, @account_done?, @project_done?, @cli_ever_connected?, @application_done?)}
            cli_ever_connected?={@cli_ever_connected?}
            cli_first_connected_at={@cli_first_connected_at}
            cli_session_count={@cli_session_count}
            onboarding_expanded={@onboarding_expanded}
            show_celebrate={@show_celebrate}
            install_steps={@install_steps}
          />

          <.application_rung
            state={rung_state(:application, @active_step, @account_done?, @project_done?, @cli_ever_connected?, @application_done?)}
            project_id={@active_project_id}
          />
        </div>
      </div>

      <script :type={Phoenix.LiveView.ColocatedHook} name=".SignUpTracking">
        // Hybrid analytics: onboarding behavior events fire via gtag directly.
        // onboarding_panel_viewed fires on mount (once, for new users).
        // install_step_copied fires when the server pushes the "install_step_copied"
        // event in response to a copy_step click.
        export default {
          mounted() {
            if (typeof gtag === "function") {
              gtag('event', 'onboarding_panel_viewed');
            }

            this.handleEvent("install_step_copied", ({ step }) => {
              if (typeof gtag === "function") {
                gtag('event', 'install_step_copied', { step: step });
              }
            });
          }
        }
      </script>
    </Layouts.app>
    """
  end

  # ── Step rungs ──────────────────────────────────────────────────────

  # Audit C3: first thing a brand-new user reads after confirming their
  # email is an account-naming form. Frame it: tell them what they're
  # about to do, give the ladder context. Only renders pre-activation
  # (no account yet). After confirmation the heading is more direct.
  defp welcome_banner(assigns) do
    ~H"""
    <div data-test="welcome-banner" class="card bg-base-200 border-l-4 border-primary">
      <div class="card-body gap-1 py-5">
        <span class="badge badge-primary badge-sm w-fit">Welcome</span>
        <h2 class="text-xl font-bold tracking-tight">
          You're in. Let's set up your workspace.
        </h2>
        <p class="text-base-content/70">
          Four steps below — each builds on the last.
        </p>
      </div>
    </div>
    """
  end

  # Audit C6: numeric summary above the ladder so the user can always see
  # where they are in the four-step sequence without counting eyebrows.
  defp ladder_progress(assigns) do
    done =
      [
        assigns.account_done?,
        assigns.project_done?,
        assigns.cli_ever_connected?,
        assigns.application_done?
      ]
      |> Enum.count(& &1)

    assigns = assign(assigns, done: done)

    ~H"""
    <div data-test="ladder-progress" class="flex flex-col gap-2 py-1">
      <ul class="steps steps-horizontal w-full text-sm">
        <li class={["step", @account_done? && "step-primary"]}>Account</li>
        <li class={["step", @project_done? && "step-primary"]}>Project</li>
        <li class={["step", @cli_ever_connected? && "step-primary"]}>Plugin</li>
        <li class={["step", @application_done? && "step-primary"]}>App</li>
      </ul>
      <div class="text-center text-xs text-base-content/60">
        <span data-test="ladder-progress-count">
          <span class={if @done == 4, do: "text-primary font-bold", else: "text-base-content font-semibold"}>
            {@done}
          </span>
          / 4 complete
        </span>
      </div>
    </div>
    """
  end

  defp account_rung(%{state: "done"} = assigns) do
    ~H"""
    <.metric_tile
      data_test="account-rung"
      state="done"
      eyebrow="Step 1 · Account"
      label="Accounts"
      value={@name || @count}
    />
    """
  end

  defp account_rung(%{state: "active"} = assigns) do
    ~H"""
    <div data-test="account-rung" data-state="active" class="card bg-base-100 border-2 border-primary shadow-sm">
      <div class="card-body gap-4">
        <div class="flex items-center gap-2">
          <span class="badge badge-primary badge-outline">Step 1 · Account</span>
          <span class="badge badge-primary">Active</span>
        </div>
        <div>
          <h2 class="text-xl font-bold tracking-tight">Name your account.</h2>
          <p class="text-base-content/70 mt-1">
            This is the workspace where your projects will live. You can rename it later.
          </p>
        </div>
        <.form for={@account_form} id="account_form" phx-submit="create_account" class="flex flex-col gap-4">
          <.input
            field={@account_form[:name]}
            type="text"
            label="Account name"
            placeholder="Acme"
            required
            autocomplete="off"
            phx-mounted={JS.focus()}
          />
          <button type="submit" class="btn btn-primary self-start" phx-disable-with="Creating…">
            Create account <.icon name="hero-arrow-right" class="size-4" />
          </button>
        </.form>
      </div>
    </div>
    """
  end

  defp account_rung(assigns) do
    ~H"""
    <.metric_tile
      data_test="account-rung"
      state="pending"
      eyebrow="Step 1 · Account"
      label="Accounts"
      value="—"
      hint="Name your workspace."
      dim
    />
    """
  end

  defp project_rung(%{state: "done"} = assigns) do
    ~H"""
    <.metric_tile
      data_test="project-rung"
      state="done"
      eyebrow="Step 2 · Project"
      label="Projects"
      value={@name || @count}
    />
    """
  end

  defp project_rung(%{state: "active"} = assigns) do
    ~H"""
    <div data-test="project-rung" data-state="active" class="card bg-base-100 border-2 border-primary shadow-sm">
      <div class="card-body gap-4">
        <div class="flex items-center gap-2">
          <span class="badge badge-primary badge-outline">Step 2 · Project</span>
          <span class="badge badge-primary">Active</span>
        </div>
        <div>
          <h2 class="text-xl font-bold tracking-tight">Name your first project.</h2>
          <p class="text-base-content/70 mt-1">
            The plugin uses this to link your local repo to the right project. You can rename it later.
          </p>
        </div>
        <.form
          for={@project_form}
          id="project_form"
          phx-change="validate_project"
          phx-submit="save_project"
          class="flex flex-col gap-4"
        >
          <.input
            field={@project_form[:name]}
            type="text"
            label="Project name"
            placeholder="my-phoenix-app"
            required
            autocomplete="off"
            phx-mounted={JS.focus()}
          />
          <%!--
            Audit S5: live preview of the derived module name so the user sees
            the silent name → CamelCase translation before submitting. Same
            derivation `save_project` uses on the server.
          --%>
          <div
            :if={@project_module_preview != ""}
            data-test="project-module-preview"
            class="text-sm text-base-content/60 -mt-2"
          >
            Will be used as module:
            <span class="font-mono text-primary">{@project_module_preview}</span>
          </div>
          <button type="submit" class="btn btn-primary self-start" phx-disable-with="Creating…">
            Create project <.icon name="hero-arrow-right" class="size-4" />
          </button>
        </.form>
      </div>
    </div>
    """
  end

  defp project_rung(assigns) do
    ~H"""
    <.metric_tile
      data_test="project-rung"
      state="pending"
      eyebrow="Step 2 · Project"
      label="Projects"
      value="—"
      hint="Name your first Phoenix project."
      dim
    />
    """
  end

  defp plugin_rung(%{state: "pending"} = assigns) do
    ~H"""
    <.metric_tile
      data_test="plugin-rung"
      state="pending"
      eyebrow="Step 3 · Plugin"
      label="Plugin"
      value="—"
      hint="Install the CodeMySpec plugin in Claude Code."
      dim
    />
    """
  end

  # Once connected the plugin step is done — collapse it to the compact
  # "Done" tile like the account/project rungs. The live session pill and
  # reinstall commands aren't needed anymore; Step 4 carries the next action.
  defp plugin_rung(%{state: "done"} = assigns) do
    ~H"""
    <.metric_tile
      data_test="plugin-rung"
      state="done"
      eyebrow="Step 3 · Plugin"
      label="Plugin"
      value="Connected"
    />
    """
  end

  # Only the ACTIVE plugin step renders the full install panel.
  defp plugin_rung(assigns) do
    ~H"""
    <div data-test="plugin-rung" data-state={@state} class="contents">
      <.onboarding_card {assigns} />
    </div>
    """
  end

  # Fourth rung: links the user out to the local app. The OAuth flow at
  # the local app is silently approved for the trusted CLI client (see
  # OAuthController.@trusted_clients), so the navigation is seamless.
  defp application_rung(%{state: "active"} = assigns) do
    assigns = assign_new(assigns, :project_id, fn -> nil end)

    ~H"""
    <a
      href={application_href(@project_id)}
      target="_blank"
      rel="noopener noreferrer"
      data-test="application-rung"
      data-state="active"
      class="card bg-primary text-primary-content shadow-sm hover:shadow-md transition-shadow block"
    >
      <div class="card-body flex-row items-center gap-4 py-4 px-6">
        <span class="badge badge-outline">Step 4 · Application</span>
        <span class="flex-1"></span>
        <span class="font-semibold inline-flex items-center gap-2">
          <.icon name="hero-arrow-top-right-on-square" class="size-4" />
          Open the local workspace · localhost:4003
        </span>
      </div>
    </a>
    """
  end

  defp application_rung(assigns) do
    ~H"""
    <div
      data-test="application-rung"
      data-state="pending"
      class="card bg-base-100 border border-base-300 opacity-60"
      aria-disabled="true"
    >
      <div class="card-body flex-row items-center gap-4 py-4 px-6">
        <span class="badge badge-ghost">Pending</span>
        <div class="flex-1">
          <div class="text-xs text-base-content/50 font-medium">Step 4 · Application</div>
          <div class="text-sm text-base-content/60 mt-0.5">
            Open the local workspace and write your first story.
          </div>
        </div>
      </div>
    </div>
    """
  end

  defp application_href(nil), do: "http://localhost:4003"
  defp application_href(project_id), do: "http://localhost:4003?project=#{project_id}"

  defp metric_tile(assigns) do
    assigns =
      assigns
      |> assign_new(:dim, fn -> false end)
      |> assign_new(:data_test, fn -> nil end)
      |> assign_new(:state, fn -> nil end)
      |> assign_new(:hint, fn -> nil end)

    ~H"""
    <div
      class={["card bg-base-100 border border-base-300", @dim && "opacity-60"]}
      data-test={@data_test}
      data-state={@state}
    >
      <div class="card-body flex-row items-center gap-4 py-4 px-6">
        <span :if={@state == "done"} class="badge badge-success gap-1">
          <.icon name="hero-check" class="size-3.5" /> Done
        </span>
        <span :if={@state == "pending"} class="badge badge-ghost">Pending</span>
        <div class="flex-1 min-w-0">
          <div class="text-xs text-base-content/50 font-medium">{@eyebrow}</div>
          <div class="font-semibold text-base-content">{@label}</div>
          <%!--
            Audit C4: pending rungs get a one-line preview so the user knows
            what each step will involve before they reach it. Skip on done
            rungs — the value already speaks for itself.
          --%>
          <div :if={@hint} class="text-sm text-base-content/60 mt-0.5">{@hint}</div>
        </div>
        <span class="text-xl font-bold tracking-tight text-base-content">{@value}</span>
      </div>
    </div>
    """
  end

  # ── Plugin install panel (existing onboarding_card) ────────────────

  defp onboarding_card(assigns) do
    ever_connected? = not is_nil(assigns[:cli_first_connected_at])
    pill_state = pill_state(assigns[:cli_session_count] || 0, ever_connected?)
    assigns = assign(assigns, ever_connected?: ever_connected?, pill_state: pill_state)

    ~H"""
    <div
      id="cms-onboarding-card"
      data-test="onboarding-card"
      data-state={if @onboarding_expanded, do: "expanded", else: "minimized"}
      class={["collapse bg-base-100 border border-base-300", (@onboarding_expanded && "collapse-open") || "collapse-close"]}
    >
      <div class="collapse-title flex items-center gap-4 py-4 px-6">
        <span class="badge badge-secondary badge-outline">Step 3 · Plugin</span>
        <span class="flex-1"></span>
        <.status_pill count={@cli_session_count} ever_connected?={@ever_connected?} state={@pill_state} />
        <button
          type="button"
          data-test="onboarding-toggle"
          phx-click="toggle_onboarding"
          class="btn btn-ghost btn-sm btn-circle"
          aria-label="Toggle install panel"
        >
          <.icon
            name={if @onboarding_expanded, do: "hero-chevron-up", else: "hero-chevron-down"}
            class="size-5"
          />
        </button>
      </div>

      <div class="collapse-content px-6 pb-6">
        <h2 class="text-xl font-bold tracking-tight">{onboarding_heading(@show_celebrate, @pill_state)}</h2>
        <p class="text-base-content/70 mt-1">{onboarding_sub(@show_celebrate, @pill_state)}</p>

        <div :if={!@show_celebrate} class="mt-5 rounded-box border border-warning/40 bg-warning/5 p-4">
          <div class="flex items-center gap-2">
            <.icon name="hero-exclamation-triangle" class="size-4 text-warning" />
            <span class="font-semibold text-sm">Before you start</span>
          </div>
          <p class="text-sm text-base-content/70 mt-1.5">
            These three commands are <strong>Claude Code slash commands</strong> — paste them
            into the Claude Code prompt, not your terminal. Launch Claude Code
            <strong>from inside your Phoenix project's root directory</strong>
            (the folder with <code class="text-primary">mix.exs</code>); CodeMySpec attaches to that directory.
          </p>
          <ul class="text-sm text-base-content/70 mt-3 list-disc pl-5 space-y-2">
            <li>
              New to Claude Code? Install it from
              <a href="https://claude.com/code" target="_blank" rel="noopener noreferrer" class="link link-primary">claude.com/code</a>.
            </li>
            <li>
              No Phoenix project yet?
              <div class="flex items-center gap-2 mt-1.5" data-test="prereq-phx-new">
                <div class="mockup-code flex-1 text-xs">
                  <pre><code>mix phx.new myapp &amp;&amp; cd myapp &amp;&amp; claude</code></pre>
                </div>
                <button
                  type="button"
                  data-test="copy-step-0"
                  data-copy="mix phx.new myapp && cd myapp && claude"
                  phx-click="copy_step"
                  phx-value-step="0"
                  class="copy-btn btn btn-sm btn-ghost"
                  aria-label="Copy mix phx.new command"
                >
                  <.icon name="hero-clipboard" class="size-4" /> Copy
                </button>
              </div>
            </li>
          </ul>
        </div>

        <ol class="mt-6 flex flex-col gap-3 list-none p-0">
          <.install_step :for={step <- @install_steps} step={step} done={@show_celebrate} />
        </ol>

        <.celebrate_callout :if={@show_celebrate} />

        <div class="mt-6 text-xs text-base-content/50">
          <span>We use Presence to show install status. We don't read your code or commands.</span>
        </div>
      </div>
    </div>
    """
  end

  defp install_step(assigns) do
    ~H"""
    <li data-test={"install-step-#{@step.n}"} class="flex items-center gap-3">
      <div class={[
        "flex items-center justify-center size-7 rounded-full shrink-0 text-sm font-semibold",
        @done && "bg-success text-success-content",
        !@done && "bg-base-300 text-base-content"
      ]}>
        <.icon :if={@done} name="hero-check" class="size-4" />
        <span :if={!@done}>{@step.n}</span>
      </div>
      <div class="mockup-code flex-1 text-xs">
        <pre><code>{@step.command}</code></pre>
      </div>
      <button
        type="button"
        data-test={"copy-step-#{@step.n}"}
        data-copy={@step.command}
        phx-click="copy_step"
        phx-value-step={@step.n}
        class="copy-btn btn btn-sm btn-ghost"
        title={@step.command}
        aria-label={"Copy command: #{@step.command}"}
      >
        <.icon name="hero-clipboard" class="size-4" /> Copy
      </button>
    </li>
    """
  end

  defp celebrate_callout(assigns) do
    ~H"""
    <div data-test="next-create-story" class="mt-6">
      <div class="divider text-xs font-medium text-base-content/50">Next</div>
      <div class="card bg-primary text-primary-content">
        <div class="card-body gap-2">
          <h3 class="text-2xl font-bold tracking-tight">
            Open the local workspace.
          </h3>
          <p class="opacity-90">
            The plugin is connected. Your first story and everything after happens in the local app.
          </p>
          <a href="http://localhost:4003" class="btn btn-sm bg-primary-content text-primary self-start mt-1">
            <.icon name="hero-arrow-top-right-on-square" class="size-4" /> http://localhost:4003
          </a>
        </div>
      </div>
    </div>
    """
  end

  defp status_pill(assigns) do
    ~H"""
    <span
      data-test="cli-status-pill"
      class={[
        "badge gap-1.5",
        @state == "connected" && "badge-success",
        @state == "disconnected" && "badge-warning",
        @state == "idle" && "badge-ghost"
      ]}
      data-state={@state}
    >
      <span class="inline-block size-2 rounded-full bg-current opacity-70"></span>
      {pill_text(@count, @ever_connected?)}
    </span>
    """
  end

  defp pill_state(0, true), do: "disconnected"
  defp pill_state(0, false), do: "idle"
  defp pill_state(_n, _), do: "connected"

  defp pill_text(0, true), do: "Claude Code not running"
  defp pill_text(0, false), do: "Not connected"
  defp pill_text(1, _), do: "Connected · 1 session"
  defp pill_text(n, _) when n > 1, do: "Connected · #{n} sessions"

  defp onboarding_heading(true, _), do: "You're connected."
  defp onboarding_heading(false, "connected"), do: "CodeMySpec is online."
  defp onboarding_heading(false, "disconnected"), do: "Claude Code isn't running."
  defp onboarding_heading(false, _), do: "Install CodeMySpec"

  defp onboarding_sub(true, _),
    do: "Plugin installed and authenticated. Use Claude Code to drive the workflow from here."

  defp onboarding_sub(false, "connected"),
    do: "Plugin installed and authenticated. Re-run any of these to reinstall on another machine."

  # The pill flips to disconnected when no CLI session is in Presence,
  # which almost always means Claude Code has been quit. Re-running
  # `/plugin marketplace add` or `/plugin install` from a non-running
  # client does nothing — only restarting Claude Code (or `/plugin-reload`
  # inside an already-running session) re-establishes the channel.
  defp onboarding_sub(false, "disconnected"),
    do:
      "Reopen Claude Code in your project directory. Inside a running session, " <>
        "you can also use /plugin-reload to reconnect."

  defp onboarding_sub(false, _),
    do:
      "These three commands install the CodeMySpec plugin in Claude Code and connect it to your account."
end
