defmodule CodeMySpecWeb.AppLive.Overview do
  use CodeMySpecWeb, :live_view

  alias CodeMySpec.Accounts
  alias CodeMySpec.Accounts.Account
  alias CodeMySpec.Projects
  alias CodeMySpec.Projects.Project
  alias CodeMySpec.UserPreferences
  alias CodeMySpec.Users.Scope

  def mount(_params, _session, socket) do
    scope = socket.assigns.current_scope

    just_confirmed =
      Phoenix.Flash.get(socket.assigns.flash, :info) == "User confirmed successfully."

    socket = assign(socket, page_title: "Overview", just_confirmed: just_confirmed)

    cond do
      is_nil(scope.active_account) and Accounts.list_accounts(scope) == [] ->
        {:ok, assign_create_account(socket)}

      is_nil(scope.active_account) ->
        [first | _] = Accounts.list_accounts(scope)

        case UserPreferences.select_active_account(scope, first.id) do
          {:ok, _} ->
            new_scope = Scope.for_user(scope.user)
            socket = Phoenix.Component.assign(socket, :current_scope, new_scope)
            {:ok, assign_project_or_ready(socket, new_scope)}

          {:error, _} ->
            {:ok, Phoenix.LiveView.redirect(socket, to: ~p"/app/accounts/picker")}
        end

      true ->
        {:ok, assign_project_or_ready(socket, scope)}
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

  defp assign_create_account(socket) do
    account_form =
      %{"type" => "personal"}
      |> Account.create_changeset()
      |> to_form(as: "account")

    assign(socket,
      step: :create_account,
      account_form: account_form,
      project_form: nil
    )
  end

  defp assign_project_or_ready(socket, scope) do
    if Projects.list_projects(scope) == [] do
      project_form =
        %Project{}
        |> Project.changeset(%{}, scope)
        |> to_form(as: "project")

      assign(socket,
        step: :project_form,
        account_form: nil,
        project_form: project_form
      )
    else
      assign(socket,
        step: :ready,
        account_form: nil,
        project_form: nil
      )
    end
  end

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
        <.create_account_step :if={@step == :create_account} account_form={@account_form} />
        <.project_step :if={@step == :project_form} project_form={@project_form} />
        <.ready_view :if={@step == :ready} />
      </div>
      <script :type={Phoenix.LiveView.ColocatedHook} name=".SignUpTracking">
        export default {
          mounted() {
            if (this.el.dataset.justConfirmed === "true" && typeof gtag === "function") {
              gtag("event", "sign_up");
            }
          }
        }
      </script>
    </Layouts.app>
    """
  end

  defp create_account_step(assigns) do
    ~H"""
    <div class="max-w-2xl mx-auto px-6 py-12">
      <h1 class="text-3xl font-bold mb-4">Welcome to CodeMySpec</h1>
      <p class="text-base-content/80 mb-10">
        Two quick steps and you're in. First, name your account — this is the
        workspace where your projects will live.
      </p>
      <div class="bg-base-200 rounded-lg p-6 border border-primary/30">
        <h2 class="text-xl font-semibold mb-3">Name your account</h2>
        <.form for={@account_form} id="account_form" phx-submit="create_account">
          <.input
            field={@account_form[:name]}
            type="text"
            label="What should we call your account?"
            required
            autocomplete="off"
            phx-mounted={JS.focus()}
          />
          <.button class="btn btn-primary w-full mt-2" phx-disable-with="Creating...">
            Create account
          </.button>
        </.form>
      </div>
    </div>
    """
  end

  defp project_step(assigns) do
    ~H"""
    <div class="max-w-2xl mx-auto px-6 py-12">
      <h1 class="text-3xl font-bold mb-4">One more step</h1>
      <p class="text-base-content/80 mb-10">
        Name your first project. The plugin uses this to link your local repo
        to the right project — you can rename it later.
      </p>
      <div class="bg-base-200 rounded-lg p-6 border border-primary/30 mb-6">
        <h2 class="text-xl font-semibold mb-3">Name your first project</h2>
        <.form for={@project_form} id="project_form" phx-submit="save_project">
          <.input
            field={@project_form[:name]}
            type="text"
            label="What should we call your first project?"
            required
            autocomplete="off"
            phx-mounted={JS.focus()}
          />
          <.button class="btn btn-primary w-full mt-2" phx-disable-with="Creating...">
            Create project
          </.button>
        </.form>
      </div>

      <.install_cards />
    </div>
    """
  end

  defp ready_view(assigns) do
    ~H"""
    <div class="max-w-2xl mx-auto px-6 py-12">
      <h1 class="text-3xl font-bold mb-6">Overview</h1>
      <div class="grid grid-cols-1 md:grid-cols-3 gap-4 mb-10">
        <div class="stat bg-base-200 rounded-lg">
          <div class="stat-title">Projects</div>
          <div class="stat-value">0</div>
        </div>
        <div class="stat bg-base-200 rounded-lg">
          <div class="stat-title">Stories</div>
          <div class="stat-value">0</div>
        </div>
        <div class="stat bg-base-200 rounded-lg">
          <div class="stat-title">Components</div>
          <div class="stat-value">0</div>
        </div>
      </div>

      <.install_cards />
    </div>
    """
  end

  defp install_cards(assigns) do
    ~H"""
    <div class="flex flex-col gap-6">
      <div class="bg-base-200 rounded-lg p-6 border border-primary/30">
        <div class="flex items-baseline justify-between mb-2 gap-3">
          <h2 class="text-xl font-semibold">
            Install the Claude Code extension
          </h2>
          <span class="badge badge-primary badge-sm shrink-0">Recommended</span>
        </div>
        <p class="text-sm text-base-content/70 mb-4">
          The full workflow — design, specs, tests, code, QA — plus a
          local admin UI and the Product Manager MCP, all bundled. Runs on port 4003.
        </p>
        <div class="mockup-code text-sm mb-4">
          <pre data-prefix="&gt;"><code>/plugin marketplace add Code-My-Spec/plugins</code></pre>
          <pre data-prefix="&gt;"><code>/plugin install codemyspec@codemyspec</code></pre>
        </div>
        <p class="text-sm text-base-content/70 mb-3">
          Then open
          <code class="text-primary">http://localhost:4003/auth</code>
          to sign in and link your first project.
        </p>
        <.link
          href={~p"/documentation/getting-started"}
          class="link link-primary text-sm"
        >
          Full walkthrough &rarr;
        </.link>
      </div>

      <div class="bg-base-200 rounded-lg p-5">
        <h3 class="font-semibold mb-2">Just want to draft stories?</h3>
        <p class="text-sm text-base-content/70 mb-3">
          Not on Claude Code? Point any MCP client at the remote Product Manager
          server. It interviews you and writes structured user stories.
        </p>
        <div class="mockup-code text-sm mb-3">
          <pre><code>Server URL: <%= CodeMySpecWeb.Endpoint.url() <> "/mcp/stories" %></code></pre>
        </div>
        <.link href={~p"/documentation/stories-mcp-setup"} class="link link-primary text-sm">
          Setup instructions &rarr;
        </.link>
      </div>
    </div>
    """
  end
end
