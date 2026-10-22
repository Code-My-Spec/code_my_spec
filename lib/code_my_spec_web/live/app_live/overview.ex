defmodule CodeMySpecWeb.AppLive.Overview do
  use CodeMySpecWeb, :live_view

  alias CodeMySpec.Accounts
  alias CodeMySpec.Accounts.Account
  alias CodeMySpec.Projects
  alias CodeMySpec.Projects.Project
  alias CodeMySpec.UserPreferences

  def mount(_params, _session, socket) do
    model_setup? = not CodeMySpec.Agents.models_configured?(socket.assigns.current_scope)

    socket =
      assign(socket,
        model_setup?: model_setup?,
        agent_installations: %{},
        checking_agents?: false,
        agent_check_error: nil,
        selected_provider: nil
      )

    socket = if model_setup? and connected?(socket), do: check_agents(socket), else: socket
    mount_overview(socket)
  end

  def handle_params(params, _uri, socket) do
    provider = params["provider"]
    provider = if provider in ["openai-codex", "claude-code"], do: provider
    {:noreply, assign(socket, :selected_provider, provider)}
  end

  defp check_agents(socket) do
    socket
    |> assign(checking_agents?: true, agent_check_error: nil)
    |> start_async(:agent_installations, fn ->
      CmsHarness.Setup.Prerequisites.agent_installations(System.user_home!())
    end)
  end

  defp mount_overview(socket) do
    scope = socket.assigns.current_scope

    socket =
      socket
      |> assign(page_title: "Overview")

    # No "send them to their last project" redirect here. Story 603 specifies
    # this path: `/app` is the primary app view, and criterion 5501 is exactly
    # "user with an account and a project sees the primary app view on /app".
    # Bouncing them to the last project satisfied the idea that a bookmark
    # should pick a landing page, and broke twelve criteria that had already
    # decided what this page is for.
    #
    # The stored project still earns its keep — it answers for `/api/issues`,
    # which has no URL to read a project from — and choosing a project is the
    # sidebar picker's job now, which is a better answer than a redirect.
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
          {:ok, _} -> {:ok, UserPreferences.scope_for(scope.user)}
          {:error, _} -> {:redirect, ~p"/app/accounts/picker"}
        end
    end
  end

  defp assign_steps(socket, scope) do
    state = build_step_state(scope)
    state = if socket.assigns.model_setup?, do: %{state | active_step: :models}, else: state

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
    active_project = scope.active_project || List.first(projects)

    %{
      account_done?: account_done?,
      account_count: if(account_done?, do: 1, else: 0),
      account_name: account_done? && scope.active_account.name,
      project_done?: project_done?,
      project_count: length(projects),
      project_name: active_project && active_project.name,
      active_project_id: active_project && active_project.id,
      active_step: active_step(account_done?, project_done?)
    }
  end

  # The active step is always the first incomplete one in the fixed order.
  # Once both are done there is no active step and the ladder is resolved.
  #
  # The ladder ends at a project. Everything past that — installing a plugin,
  # signing in to the local app — happened somewhere this page cannot see, so
  # a rung for it could only ever sit unfinished and make a working setup look
  # broken.
  defp active_step(false, _), do: :account
  defp active_step(true, false), do: :project
  defp active_step(true, true), do: nil

  # A rung is "done" if its prerequisite has been fulfilled, "active"
  # if it's the current first-incomplete step, otherwise "pending".
  # Multi-clause dispatch keeps cyclomatic complexity flat — each
  # rung's done-condition matches a single arg position.
  defp rung_state(step, step, _, _), do: "active"
  defp rung_state(:account, _, true, _), do: "done"
  defp rung_state(:project, _, _, true), do: "done"
  defp rung_state(_, _, _, _), do: "pending"

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

  def handle_event("check_agents", _params, %{assigns: %{model_setup?: true}} = socket) do
    {:noreply, check_agents(socket)}
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
      {:ok, _project} ->
        # Back to /app, as before — only the preference write is gone. Nothing
        # downstream requires an active project any more, so there is no state
        # to pre-select and no gate that would bounce the user if we didn't.
        {:noreply, push_navigate(socket, to: ~p"/app")}

      {:error, changeset} ->
        {:noreply, assign(socket, project_form: to_form(changeset, as: "project"))}
    end
  end

  def handle_async(:agent_installations, {:ok, installations}, socket) do
    {:noreply, assign(socket, agent_installations: installations, checking_agents?: false)}
  end

  def handle_async(:agent_installations, {:exit, _reason}, socket) do
    {:noreply,
     assign(socket,
       checking_agents?: false,
       agent_check_error: "Could not check agent installations. Try checking again."
     )}
  end

  def handle_info(:agent_models_saved, socket) do
    {:noreply, socket |> put_flash(:info, "Agent models saved") |> push_navigate(to: ~p"/app")}
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
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      project={assigns[:project]}
      projects={assigns[:projects] || []}
    >
      <div id="onboarding-page" phx-hook=".SignUpTracking">
        <div class="mx-auto max-w-3xl flex flex-col gap-4">
          <.ladder_progress
            models_done?={!@model_setup?}
            account_done?={@account_done?}
            project_done?={@project_done?}
            active_step={@active_step}
          />

          <CodeMySpecWeb.AppLive.ModelSetup.wizard
            :if={@model_setup?}
            current_scope={@current_scope}
            installations={@agent_installations}
            checking?={@checking_agents?}
            error={@agent_check_error}
            selected_provider={@selected_provider}
          />
          <div :if={!@model_setup?} data-test="models-rung" data-state="done">
            <.metric_tile
              state="done"
              eyebrow="Step 1 · Agent models"
              label="Agent models"
              value="Configured"
            />
            <.link navigate={~p"/app/agent-models"} class="link text-sm">Change agent models</.link>
          </div>

          <.welcome_banner :if={!@model_setup? and !@account_done?} />

          <.account_rung
            state={rung_state(:account, @active_step, @account_done?, @project_done?)}
            count={@account_count}
            name={@account_name}
            account_form={@account_form}
          />

          <.project_rung
            state={rung_state(:project, @active_step, @account_done?, @project_done?)}
            count={@project_count}
            name={@project_name}
            project_form={@project_form}
            project_module_preview={@project_module_preview}
          />
        </div>
      </div>

      <script :type={Phoenix.LiveView.ColocatedHook} name=".SignUpTracking">
        // Hybrid analytics: onboarding behavior events fire via gtag directly.
        // onboarding_panel_viewed fires on mount (once, for new users).
        export default {
          mounted() {
            if (typeof gtag === "function") {
              gtag('event', 'onboarding_panel_viewed');
            }
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
          Name your workspace and your first project.
        </p>
      </div>
    </div>
    """
  end

  # Audit C6: numeric summary above the ladder so the user can always see
  # where they are in the sequence without counting eyebrows.
  defp ladder_progress(assigns) do
    steps = [
      %{key: :models, label: "Agent models", done?: assigns.models_done?},
      %{key: :account, label: "Account", done?: assigns.account_done?},
      %{key: :project, label: "Project", done?: assigns.project_done?}
    ]

    assigns = assign(assigns, steps: steps, done: Enum.count(steps, & &1.done?))

    ~H"""
    <div data-test="ladder-progress" class="flex flex-col gap-2 py-1">
      <ul class="steps steps-horizontal w-full text-sm" aria-label="Onboarding progress">
        <li
          :for={step <- @steps}
          data-step={step.key}
          data-state={
            if step.done?,
              do: "done",
              else: if(step.key == @active_step, do: "active", else: "pending")
          }
          aria-current={if step.key == @active_step, do: "step"}
          class={["step", (step.done? or step.key == @active_step) && "step-primary"]}
        >
          {step.label}
        </li>
      </ul>
      <div class="text-center text-xs text-base-content/60">
        <span data-test="ladder-progress-count">
          <span class={
            if @done == 3, do: "text-primary font-bold", else: "text-base-content font-semibold"
          }>
            {@done}
          </span>
          / 3 complete
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
      eyebrow="Step 2 · Account"
      label="Accounts"
      value={@name || @count}
    />
    """
  end

  defp account_rung(%{state: "active"} = assigns) do
    ~H"""
    <div
      data-test="account-rung"
      data-state="active"
      class="card bg-base-100 border-2 border-primary shadow-sm"
    >
      <div class="card-body gap-4">
        <div class="flex items-center gap-2">
          <span class="badge badge-primary badge-outline">Step 2 · Account</span>
          <span class="badge badge-primary">Active</span>
        </div>
        <div>
          <h2 class="text-xl font-bold tracking-tight">Name your account.</h2>
          <p class="text-base-content/70 mt-1">
            This is the workspace where your projects will live. You can rename it later.
          </p>
        </div>
        <.form
          for={@account_form}
          id="account_form"
          phx-submit="create_account"
          class="flex flex-col gap-4"
        >
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
      eyebrow="Step 2 · Account"
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
      eyebrow="Step 3 · Project"
      label="Projects"
      value={@name || @count}
    />
    """
  end

  defp project_rung(%{state: "active"} = assigns) do
    ~H"""
    <div
      data-test="project-rung"
      data-state="active"
      class="card bg-base-100 border-2 border-primary shadow-sm"
    >
      <div class="card-body gap-4">
        <div class="flex items-center gap-2">
          <span class="badge badge-primary badge-outline">Step 3 · Project</span>
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
      eyebrow="Step 3 · Project"
      label="Projects"
      value="—"
      hint="Name your first Phoenix project."
      dim
    />
    """
  end

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
end
