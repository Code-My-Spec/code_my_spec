defmodule CodeMySpecWeb.AppLive.Overview do
  use CodeMySpecWeb, :live_view

  alias CodeMySpec.Accounts
  alias CodeMySpec.Accounts.Account
  alias CodeMySpec.Analytics
  alias CodeMySpec.Projects
  alias CodeMySpec.Projects.Project
  alias CodeMySpec.Stories
  alias CodeMySpec.UserPreferences
  alias CodeMySpec.Users
  alias CodeMySpec.Users.Scope
  alias CodeMySpecWeb.CliChannel
  alias CodeMySpecWeb.Presence

  @install_steps [
    %{n: 1, command: "/plugin marketplace add Code-My-Spec/plugins"},
    %{n: 2, command: "/plugin install codemyspec@codemyspec"},
    %{n: 3, command: "/codemyspec:authenticate"}
  ]

  def mount(_params, _session, socket) do
    scope = socket.assigns.current_scope

    just_confirmed =
      Phoenix.Flash.get(socket.assigns.flash, :info) == "User confirmed successfully."

    socket =
      socket
      |> assign(page_title: "Overview", just_confirmed: just_confirmed)
      |> assign_onboarding_state(scope.user)
      |> dispatch_onboarding_view(scope.user)

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

    %{
      account_done?: account_done?,
      account_count: if(account_done?, do: 1, else: 0),
      account_name: account_done? && scope.active_account.name,
      project_done?: project_done?,
      project_count: length(projects),
      project_name: scope.active_project && scope.active_project.name,
      stories_count: stories_count(scope),
      cli_ever_connected?: cli_ever_connected?,
      active_step: active_step(account_done?, project_done?, cli_ever_connected?)
    }
  end

  defp stories_count(%{active_project: nil}), do: 0
  defp stories_count(scope), do: length(Stories.list_stories(scope))

  defp active_step(false, _, _), do: :account
  defp active_step(true, false, _), do: :project
  defp active_step(true, true, false), do: :plugin
  defp active_step(true, true, true), do: :stories

  defp assign_account_form(socket) do
    if socket.assigns.account_done? do
      assign(socket, :account_form, nil)
    else
      form =
        %{"type" => "personal"}
        |> Account.create_changeset()
        |> to_form(as: "account")

      assign(socket, :account_form, form)
    end
  end

  defp assign_project_form(socket, scope) do
    if socket.assigns.project_done? do
      assign(socket, :project_form, nil)
    else
      form =
        %Project{}
        |> Project.changeset(%{}, scope)
        |> to_form(as: "project")

      assign(socket, :project_form, form)
    end
  end

  def handle_event("create_account", %{"account" => params}, socket) do
    scope = socket.assigns.current_scope

    case Accounts.create_personal_account(scope, params) do
      {:ok, account} ->
        {:ok, _} = UserPreferences.select_active_account(scope, account.id)
        {:noreply, push_navigate(socket, to: ~p"/app")}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply,
         assign(socket, account_form: to_form(changeset, as: "account", action: :insert))}
    end
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

  def handle_event("toggle_onboarding", _params, socket) do
    {:noreply, assign(socket, onboarding_expanded: !socket.assigns.onboarding_expanded)}
  end

  def handle_event("copy_step", %{"step" => step_str}, socket) do
    case Integer.parse(step_str) do
      {step, ""} when step in 1..3 ->
        user = socket.assigns.current_scope.user
        payload = %{user_id: user.id, step: step}

        Analytics.dispatch(:install_step_copied, payload, :browser)

        {:noreply,
         push_event(socket, "analytics", %{
           name: "install_step_copied",
           params: payload
         })}

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

  def handle_info(_msg, socket), do: {:noreply, socket}

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
        |> assign(:onboarding_expanded, true)

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

  defp dispatch_onboarding_view(socket, user) do
    if connected?(socket) and not Users.cli_ever_connected?(user) do
      payload = %{user_id: user.id}
      Analytics.dispatch(:onboarding_panel_viewed, payload, :browser)

      push_event(socket, "analytics", %{
        name: "onboarding_panel_viewed",
        params: payload
      })
    else
      socket
    end
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
        data-just-confirmed={to_string(@just_confirmed)}
      >
        <div class="mx-auto max-w-2xl flex flex-col gap-4">
          <.account_rung
            done?={@account_done?}
            count={@account_count}
            name={@account_name}
            active?={@active_step == :account}
            account_form={@account_form}
          />

          <.project_rung
            :if={@account_done?}
            done?={@project_done?}
            count={@project_count}
            name={@project_name}
            active?={@active_step == :project}
            project_form={@project_form}
          />

          <.plugin_rung
            :if={@account_done?}
            active?={
              not @cli_ever_connected? or @onboarding_expanded or @show_celebrate
            }
            cli_ever_connected?={@cli_ever_connected?}
            cli_first_connected_at={@cli_first_connected_at}
            cli_session_count={@cli_session_count}
            onboarding_expanded={@onboarding_expanded}
            show_celebrate={@show_celebrate}
            install_steps={@install_steps}
          />

          <.stories_rung
            :if={@project_done?}
            count={@stories_count}
            active?={@active_step == :stories}
          />

          <.alternative_mcp_card />
        </div>
      </div>
      <script :type={Phoenix.LiveView.ColocatedHook} name=".SignUpTracking">
        export default {
          mounted() {
            if (this.el.dataset.justConfirmed === "true" && typeof gtag === "function") {
              gtag("event", "sign_up");
            }
            this.handleEvent("analytics", ({ name, params }) => {
              if (typeof gtag === "function") {
                gtag("event", name, params || {});
              }
            });
          }
        }
      </script>
    </Layouts.app>
    """
  end

  # ── Step rungs ──────────────────────────────────────────────────────

  defp account_rung(%{done?: true} = assigns) do
    ~H"""
    <.metric_tile eyebrow="// step 01 ✓ account" label="Accounts" value={@name || @count} />
    """
  end

  defp account_rung(%{active?: true} = assigns) do
    ~H"""
    <div class="cms-onboarding">
      <div class="px-7 py-7">
        <div class="cms-onboarding-eyebrow mb-2.5">// step 01 · account</div>
        <h2 class="cms-onboarding-heading">Name your account.</h2>
        <p class="cms-onboarding-sub mb-6">
          This is the workspace where your projects will live. You can rename it later.
        </p>
        <.form for={@account_form} id="account_form" phx-submit="create_account" class="flex flex-col gap-4">
          <.input
            field={@account_form[:name]}
            type="text"
            label="Account name"
            required
            autocomplete="off"
            phx-mounted={JS.focus()}
          />
          <button type="submit" class="cms-onboarding-cta self-start" phx-disable-with="Creating…">
            <span>▸</span> Create account
          </button>
        </.form>
      </div>
    </div>
    """
  end

  defp project_rung(%{done?: true} = assigns) do
    ~H"""
    <.metric_tile eyebrow="// step 02 ✓ project" label="Projects" value={@name || @count} />
    """
  end

  defp project_rung(%{active?: true} = assigns) do
    ~H"""
    <div class="cms-onboarding">
      <div class="px-7 py-7">
        <div class="cms-onboarding-eyebrow mb-2.5">// step 02 · project</div>
        <h2 class="cms-onboarding-heading">Name your first project.</h2>
        <p class="cms-onboarding-sub mb-6">
          The plugin uses this to link your local repo to the right project. You can rename it later.
        </p>
        <.form for={@project_form} id="project_form" phx-submit="save_project" class="flex flex-col gap-4">
          <.input
            field={@project_form[:name]}
            type="text"
            label="Project name"
            required
            autocomplete="off"
            phx-mounted={JS.focus()}
          />
          <button type="submit" class="cms-onboarding-cta self-start" phx-disable-with="Creating…">
            <span>▸</span> Create project
          </button>
        </.form>
      </div>
    </div>
    """
  end

  defp plugin_rung(%{active?: true} = assigns) do
    ~H"""
    <.onboarding_card {assigns} />
    """
  end

  defp plugin_rung(%{cli_ever_connected?: true} = assigns) do
    pill_state = pill_state(assigns.cli_session_count, true)
    assigns = assign(assigns, pill_state: pill_state)

    ~H"""
    <div
      data-test="onboarding-card"
      data-state="minimized"
      class="cms-onboarding"
    >
      <div class="flex items-center gap-4 px-6 py-5">
        <span class="cms-onboarding-eyebrow flex items-center gap-2">
          <span style="color: var(--color-cms-red); font-size: 13px;">▸</span>
          Plugin
        </span>
        <span class="flex-1"></span>
        <.status_pill count={@cli_session_count} ever_connected?={true} state={@pill_state} />
        <button
          type="button"
          data-test="onboarding-toggle"
          phx-click="toggle_onboarding"
          class="cms-onboarding-toggle"
          aria-label="Expand install steps"
        >
          ▾
        </button>
      </div>
    </div>
    """
  end

  defp plugin_rung(assigns) do
    ~H"""
    <.metric_tile eyebrow="// step 03 · plugin" label="Plugin" value="—" dim />
    """
  end

  defp stories_rung(%{count: 0, active?: true} = assigns) do
    ~H"""
    <div class="cms-onboarding">
      <div class="flex items-center gap-4 px-6 py-5">
        <span class="cms-onboarding-eyebrow flex items-center gap-2">
          <span style="color: var(--color-cms-red); font-size: 13px;">▸</span>
          Stories
        </span>
        <span
          class="cms-onboarding-heading"
          style="font-size: 22px; line-height: 1; color: var(--color-cms-text);"
        >
          0
        </span>
        <span class="flex-1"></span>
        <.link navigate={~p"/app/stories/new"} class="cms-onboarding-cta">
          <span>▸</span> Create your first story
        </.link>
      </div>
    </div>
    """
  end

  defp stories_rung(assigns) do
    ~H"""
    <.metric_tile eyebrow="// step 04 · stories" label="Stories" value={@count} />
    """
  end

  defp metric_tile(assigns) do
    assigns = assign_new(assigns, :dim, fn -> false end)

    ~H"""
    <div
      class="cms-onboarding"
      style={if @dim, do: "opacity: 0.55;", else: ""}
    >
      <div class="flex items-center gap-4 px-6 py-5">
        <span class="cms-onboarding-eyebrow">{@eyebrow}</span>
        <span class="flex-1"></span>
        <span class="cms-onboarding-eyebrow" style="opacity: 0.7;">{@label}</span>
        <span
          class="cms-onboarding-heading"
          style="font-size: 22px; line-height: 1; color: var(--color-cms-text);"
        >
          {@value}
        </span>
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
      data-test="onboarding-card"
      data-state={if @onboarding_expanded, do: "expanded", else: "minimized"}
      class="cms-onboarding"
    >
      <div :if={not @onboarding_expanded} class="flex items-center gap-4 px-6 py-5">
        <span class="cms-onboarding-eyebrow flex items-center gap-2">
          <span style="color: var(--color-cms-red); font-size: 13px;">▸</span>
          CodeMySpec plugin
        </span>
        <span class="flex-1"></span>
        <.status_pill count={@cli_session_count} ever_connected?={@ever_connected?} state={@pill_state} />
        <button
          type="button"
          data-test="onboarding-toggle"
          phx-click="toggle_onboarding"
          class="cms-onboarding-toggle"
          aria-label="Expand install steps"
        >
          ▾
        </button>
      </div>

      <div :if={@onboarding_expanded} class="px-7 py-7">
        <div class="flex items-start gap-4">
          <div class="flex-1 min-w-0">
            <div class="cms-onboarding-eyebrow mb-2.5">// step 03 · plugin</div>
            <h2 class="cms-onboarding-heading">{onboarding_heading(@show_celebrate, @pill_state)}</h2>
            <p class="cms-onboarding-sub">{onboarding_sub(@show_celebrate, @pill_state)}</p>
          </div>
          <div class="flex items-center gap-2.5 pt-1 shrink-0">
            <.status_pill count={@cli_session_count} ever_connected?={@ever_connected?} state={@pill_state} />
            <button
              type="button"
              data-test="onboarding-toggle"
              phx-click="toggle_onboarding"
              class="cms-onboarding-toggle"
              aria-label="Minimize install panel"
            >
              ▴
            </button>
          </div>
        </div>

        <ol class="mt-6 flex flex-col gap-3.5 list-none p-0">
          <.install_step :for={step <- @install_steps} step={step} done={@show_celebrate} />
        </ol>

        <.celebrate_callout :if={@show_celebrate} />

        <div class="cms-onboarding-privacy">
          <span>We use Presence to show install status. We don't read your code or commands.</span>
        </div>
      </div>
    </div>
    """
  end

  defp install_step(assigns) do
    ~H"""
    <li
      data-test={"install-step-#{@step.n}"}
      class="grid items-center gap-3.5"
      style="grid-template-columns: 32px 1fr auto;"
    >
      <div class="cms-onboarding-step-cell" data-done={to_string(@done)}>
        {if @done, do: "✓", else: @step.n}
      </div>
      <div class="cms-onboarding-cmd">
        <span class="cms-onboarding-cmd-prompt">▸</span>
        <code>{@step.command}</code>
      </div>
      <button
        type="button"
        data-test={"copy-step-#{@step.n}"}
        data-clipboard-text={@step.command}
        phx-click="copy_step"
        phx-value-step={@step.n}
        class="cms-onboarding-copy"
        title={@step.command}
        aria-label={"Copy command: #{@step.command}"}
      >
        Copy
      </button>
    </li>
    """
  end

  defp celebrate_callout(assigns) do
    ~H"""
    <div data-test="next-create-story" class="cms-onboarding-celebrate mt-6">
      <div class="cms-onboarding-eyebrow flex items-center gap-2.5 mb-2.5">
        <span>// next</span>
        <span class="flex-1 h-px max-w-[120px]" style="background: linear-gradient(90deg, var(--color-cms-red), transparent);"></span>
      </div>
      <h3 class="cms-onboarding-heading" style="font-size: 24px;">
        Create your first user story.
      </h3>
      <p class="cms-onboarding-sub" style="margin-bottom: 16px;">
        Use Claude Code to start your first story — paste the prompt below or open the plugin and ask it to create your first story.
      </p>
      <.link navigate={~p"/app/stories/new"} class="cms-onboarding-cta">
        <span>▸</span> Open story creator
      </.link>
    </div>
    """
  end

  defp status_pill(assigns) do
    ~H"""
    <span data-test="cli-status-pill" class="cms-onboarding-pill" data-state={@state}>
      <span class="cms-pill-dot"></span>
      {pill_text(@count, @ever_connected?)}
    </span>
    """
  end

  defp pill_state(0, true), do: "disconnected"
  defp pill_state(0, false), do: "idle"
  defp pill_state(_n, _), do: "connected"

  defp pill_text(0, true), do: "Disconnected"
  defp pill_text(0, false), do: "Not connected"
  defp pill_text(1, _), do: "Connected · 1 session"
  defp pill_text(n, _) when n > 1, do: "Connected · #{n} sessions"

  defp onboarding_heading(true, _), do: "You're connected."
  defp onboarding_heading(false, "connected"), do: "CodeMySpec is online."
  defp onboarding_heading(false, "disconnected"), do: "CodeMySpec is offline."
  defp onboarding_heading(false, _), do: "Install CodeMySpec"

  defp onboarding_sub(true, _),
    do: "Plugin installed and authenticated. Use Claude Code to drive the workflow from here."

  defp onboarding_sub(false, "connected"),
    do: "Plugin installed and authenticated. Re-run any of these to reinstall on another machine."

  defp onboarding_sub(false, "disconnected"),
    do: "Restart Claude Code, or re-run any of these to reconnect:"

  defp onboarding_sub(false, _),
    do:
      "These three commands install the CodeMySpec plugin in Claude Code and connect it to your account."

  defp alternative_mcp_card(assigns) do
    ~H"""
    <div class="cms-onboarding">
      <div class="px-7 py-7">
        <div class="cms-onboarding-eyebrow mb-2.5">// alt · remote mcp</div>
        <h3 class="cms-onboarding-heading" style="font-size: 22px;">
          Just want to draft stories?
        </h3>
        <p class="cms-onboarding-sub mb-5">
          Not on Claude Code? Point any MCP client at the remote Product Manager
          server. It interviews you and writes structured user stories.
        </p>
        <div class="cms-onboarding-cmd mb-4">
          <span class="cms-onboarding-cmd-prompt">▸</span>
          <code>Server URL: {CodeMySpecWeb.Endpoint.url() <> "/mcp/product-manager"}</code>
        </div>
        <.link href={~p"/documentation/stories-mcp-setup"} class="cms-onboarding-cta">
          <span>▸</span> Setup instructions
        </.link>
      </div>
    </div>
    """
  end
end
