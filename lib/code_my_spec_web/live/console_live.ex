defmodule CodeMySpecWeb.ConsoleLive do
  @moduledoc """
  The project console — step 6 of the provisioning-page redesign (held on
  its own branch for review, not promoted).

  A new LiveView rather than new `live_action`s on `ProvisioningLive`: the
  two pages' render trees don't share a shape, and bolting a sidebar-and-tabs
  console onto the page step 5 just finished de-nesting would undo that work.
  `ProvisioningLive` keeps serving `/provisioning` unchanged — every spex that
  targets it still passes — while this serves the new `/console` routes
  side by side.

  ## Layout

  A sidebar (Overview, Resources, Deploys, Secrets, Credentials, Activity,
  Settings) plus a header `EnvironmentSwitcher`. Credentials, Secrets and
  Settings are project-wide; Overview, Resources and Deploys are scoped to
  the selected environment via `?env=`, patched rather than navigated so
  switching environments does not remount the page — the same ?param-over-
  route shape `AgentConversationLive` already uses for its own in-page
  selection.

  ## What's real here and what's a first pass

  Resources lists one row per step key and reuses the exact per-step Config
  components step 5 extracted (DnsConfig, DeployConfig, and so on) for each
  resource's Config tab — the plan's "servers / DNS-domain / mail in and
  out / storage-backups / publishing / feedback widget" grouping would
  combine several step keys per resource, which this does not do yet.
  Checks and Activity tabs are placeholders: the five probes
  (storage_probe, check_domain, content_publish, probe_restore,
  mail_inbound_probe) still run exactly as they did on the old page, not yet
  moved into a DiagnosticsPanel or converted to async — that is still owed,
  and is the main thing left before this is more than a layout.

  Overview's "recent activity" is derived from each step's own
  started_at/completed_at/verified_at, sorted — not a persisted event log.
  There is no audit trail of credential saves, secret writes or environment
  edits yet, so those never appear here. A real Activity feed needs that
  log built first.
  """

  use CodeMySpecWeb, :live_view

  alias CodeMySpec.Generators.DeployArtifacts
  alias CodeMySpec.Projects
  alias CodeMySpec.Provisioning
  alias CodeMySpec.Users.Scope

  alias CodeMySpecWeb.ConsoleLive.Components.EnvironmentSwitcher
  alias CodeMySpecWeb.ConsoleLive.Components.ResourceDetail
  alias CodeMySpecWeb.ConsoleLive.Components.Sidebar
  alias CodeMySpecWeb.ProvisioningLive.Components.CredentialsForm
  alias CodeMySpecWeb.ProvisioningLive.Components.EnvironmentsForm
  alias CodeMySpecWeb.ProvisioningLive.Components.SecretsForm

  alias CodeMySpec.Provisioning.Credentials

  @impl true
  def mount(params, _session, socket) do
    # Same resolution as ProvisioningLive.scope_for/2 — the project in the
    # URL, not whichever one happens to be active (criterion 8051). Kept as
    # its own copy rather than a shared import: this page is on its own
    # branch precisely so it can move independently of the page it is
    # replacing, and that page's mount is settled, promoted code.
    case scope_for(socket.assigns.current_scope, params["project_id"]) do
      {:ok, scope} ->
        {:ok, assign(socket, :current_scope, scope)}

      :error ->
        {:ok,
         socket
         |> put_flash(:error, "That project is not yours, or does not exist.")
         |> push_navigate(to: ~p"/app/projects")}
    end
  end

  @impl true
  def handle_params(params, _url, socket) do
    scope = socket.assigns.current_scope
    options = Provisioning.setup_options(scope)
    plan = Provisioning.plan(scope, options)
    environments = Provisioning.environment_names(scope)

    environment =
      params["env"] || Provisioning.primary_environment(scope) || List.first(environments)

    socket =
      socket
      |> assign(:options, options)
      |> assign(:plan, plan)
      |> assign(:environments, environments)
      |> assign(:environment, environment)
      |> assign(:resource_key, string_to_key(params["key"]))
      |> assign(:tab, params["tab"] || "config")
      |> assign_new(:credentials, fn -> Credentials.list(scope) end)
      |> assign_new(:missing_credentials, fn -> Credentials.missing(scope) end)
      |> assign(:environment_rows, Provisioning.environments(scope))
      |> assign(:sops_recipients, Provisioning.Steps.recipients(scope, environments))
      |> assign(:secret_sources, secret_sources(environments))
      |> assign_new(:secret_error, fn -> nil end)

    {:noreply, socket}
  end

  defp string_to_key(nil), do: nil
  defp string_to_key(key), do: String.to_existing_atom(key)

  defp secret_sources(environments) do
    for consumer <- ["local", "deploy"], environment <- environments do
      %{consumer: consumer, path: Provisioning.Sops.env_file(environment)}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      current_path={@current_path}
      project={assigns[:project]}
      projects={assigns[:projects] || []}
    >
      <div class="drawer lg:drawer-open" data-test="console">
        <input id="console-drawer" type="checkbox" class="drawer-toggle" />

        <div class="drawer-content p-4 lg:p-8 flex flex-col gap-4">
          <div class="flex items-center justify-between gap-4">
            <label for="console-drawer" class="btn btn-ghost drawer-button lg:hidden">
              Menu
            </label>
            <EnvironmentSwitcher.environment_switcher
              :if={@live_action in [:overview, :resources, :resource_detail, :deploys]}
              environment={@environment}
              environments={@environments}
              base_path={~p"/app/projects/#{@current_scope.active_project_id}/console"}
              live_action={@live_action}
            />
          </div>

          {render_section(assigns)}
        </div>

        <div class="drawer-side">
          <label for="console-drawer" class="drawer-overlay"></label>
          <Sidebar.sidebar
            live_action={@live_action}
            project_id={@current_scope.active_project_id}
          />
        </div>
      </div>
    </Layouts.app>
    """
  end

  defp render_section(%{live_action: :overview} = assigns) do
    ~H"""
    <section data-test="console-overview" class="flex flex-col gap-6">
      <div data-test="setup-checklist" class="card bg-base-100">
        <div class="card-body">
          <h2 class="card-title">Setup checklist</h2>
          <p data-test="setup-checklist-count" class="text-sm opacity-70">
            {setup_done_count(@plan)}/{length(@plan)} done
          </p>
          <ul class="mt-2 flex flex-col gap-1">
            <li
              :for={step <- @plan}
              data-test="setup-checklist-item"
              data-step={step.key}
              data-state={step.state}
              class="flex items-center justify-between text-sm"
            >
              <span>{step.label}</span>
              <span class="badge badge-sm">{step.state}</span>
            </li>
          </ul>
        </div>
      </div>

      <div
        data-test="console-resource-grid"
        class="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-3 gap-3"
      >
        <.link
          :for={step <- environment_scoped(@plan, @environment)}
          navigate={
            ~p"/app/projects/#{@current_scope.active_project_id}/console/resources/#{step.key}?env=#{@environment}"
          }
          data-test="resource-card"
          data-step={step.key}
          class="card bg-base-100 hover:shadow-md transition-shadow"
        >
          <div class="card-body p-4">
            <h3 class="card-title text-base">{step.label}</h3>
            <span class="badge badge-sm w-fit">{step.state}</span>
          </div>
        </.link>
      </div>

      <div data-test="console-activity" class="card bg-base-100">
        <div class="card-body">
          <h2 class="card-title">Recent activity</h2>
          <p :if={recent_activity(@plan) == []} class="opacity-70 text-sm">Nothing yet.</p>
          <ul class="mt-2 flex flex-col gap-1">
            <li
              :for={entry <- recent_activity(@plan)}
              data-test="activity-entry"
              data-step={entry.step}
              data-at={DateTime.to_iso8601(entry.at)}
              class="text-sm opacity-70"
            >
              {entry.step} {entry.kind} at {entry.at}
            </li>
          </ul>
        </div>
      </div>
    </section>
    """
  end

  defp render_section(%{live_action: :resources} = assigns) do
    ~H"""
    <section data-test="console-resources" class="flex flex-col gap-2">
      <.link
        :for={step <- environment_scoped(@plan, @environment)}
        navigate={
          ~p"/app/projects/#{@current_scope.active_project_id}/console/resources/#{step.key}?env=#{@environment}"
        }
        data-test="resource-row"
        data-step={step.key}
        class="card bg-base-100 hover:shadow-md transition-shadow"
      >
        <div class="card-body p-4 flex-row items-center justify-between">
          <div>
            <h3 class="font-semibold">{step.label}</h3>
            <p class="text-sm opacity-70">{step.why}</p>
          </div>
          <span class="badge">{step.state}</span>
        </div>
      </.link>
    </section>
    """
  end

  defp render_section(%{live_action: :resource_detail} = assigns) do
    ~H"""
    <ResourceDetail.resource_detail
      step={resource_step(@plan, @resource_key, @environment)}
      environments={@environments}
      age_key_environments={age_key_environments(@current_scope, @environments)}
      runs_in_flight?={Provisioning.runs_in_flight?(@current_scope)}
      tab={@tab}
      project_id={@current_scope.active_project_id}
      environment={@environment}
    />
    """
  end

  defp render_section(%{live_action: :deploys} = assigns) do
    ~H"""
    <section data-test="console-deploys" class="flex flex-col gap-4">
      <p class="text-sm opacity-70">
        Deploy files generation lives here now — moved off the old setup page.
      </p>
      <.button data-test="generate-project" phx-click="generate_project" class="btn">
        Generate deploy files
      </.button>

      <div
        :for={step <- deploy_steps(@plan, @environment)}
        data-test="deploy-row"
        data-environment={step.environment}
        class="card bg-base-100"
      >
        <div class="card-body">
          <h3 class="card-title text-base">
            Deploy {step.environment} <span class="badge">{step.state}</span>
          </h3>
          <.form for={%{}} as={:deploy} phx-submit="run_step_with_environment" class="flex gap-2">
            <input type="hidden" name="key" value={step.key} />
            <input type="hidden" name="environment" value={step.environment} />
            <.button type="submit" data-test="deploy-submit" class="btn btn-primary">
              {if step.state == :errored, do: "Retry", else: "Deploy"}
            </.button>
          </.form>
        </div>
      </div>
    </section>
    """
  end

  defp render_section(%{live_action: :secrets} = assigns) do
    ~H"""
    <section data-test="console-secrets">
      <SecretsForm.secrets_form
        return_to={~p"/app/projects/#{@current_scope.active_project_id}/console"}
        environments={@environments}
        secret_error={@secret_error}
        sops_recipients={@sops_recipients}
        secret_sources={@secret_sources}
      />
    </section>
    """
  end

  defp render_section(%{live_action: :credentials} = assigns) do
    ~H"""
    <section data-test="console-credentials">
      <CredentialsForm.credentials_form
        return_to={~p"/app/projects/#{@current_scope.active_project_id}/console"}
        missing_credentials={@missing_credentials}
        credentials={@credentials}
      />
    </section>
    """
  end

  defp render_section(%{live_action: :activity} = assigns) do
    ~H"""
    <section data-test="console-activity-page" class="flex flex-col gap-1">
      <p :if={recent_activity(@plan) == []} class="opacity-70 text-sm">Nothing yet.</p>
      <div
        :for={entry <- recent_activity(@plan)}
        data-test="activity-entry"
        data-step={entry.step}
        data-at={DateTime.to_iso8601(entry.at)}
        class="text-sm opacity-70 border-b border-base-200 py-1"
      >
        {entry.step} {entry.kind} at {entry.at}
      </div>
    </section>
    """
  end

  defp render_section(%{live_action: :settings} = assigns) do
    ~H"""
    <section data-test="console-settings">
      <EnvironmentsForm.environments_form
        return_to={~p"/app/projects/#{@current_scope.active_project_id}/console"}
        environment_rows={@environment_rows}
      />
    </section>
    """
  end

  defp setup_done_count(plan), do: Enum.count(plan, &(&1.state == :done))

  # Project-wide steps show regardless of the selected environment; a
  # per-environment step shows only its own environment's row, so switching
  # environments shows a different deploy/dns/server row rather than every
  # environment's at once.
  defp environment_scoped(plan, environment) do
    Enum.filter(plan, &(is_nil(&1.environment) or &1.environment == environment))
  end

  defp deploy_steps(plan, environment) do
    Enum.filter(plan, &(&1.key == :deploy and &1.environment == environment))
  end

  defp resource_step(plan, key, environment) do
    plan
    |> environment_scoped(environment)
    |> Enum.find(&(&1.key == key))
  end

  defp age_key_environments(scope, environments) do
    Enum.filter(
      environments,
      &CodeMySpec.ProjectSecrets.has_value?(scope, "age_private_key_#{&1}")
    )
  end

  # Not a persisted event log — see the moduledoc. Every timestamp a step
  # already carries, newest first, capped at 10 the same way the plan's
  # Overview calls for.
  defp recent_activity(plan) do
    for step <- plan,
        {kind, at} <- [
          {"started", step.started_at},
          {"completed", step.completed_at},
          {"verified", step.verified_at}
        ],
        not is_nil(at) do
      %{step: step.key, kind: kind, at: at}
    end
    |> Enum.sort_by(& &1.at, {:desc, DateTime})
    |> Enum.take(10)
  end

  # Same as ProvisioningLive.scope_for/2 — see the mount/3 comment above for
  # why this is its own copy rather than a shared import.
  defp scope_for(%{active_project: project} = scope, nil),
    do: {:ok, with_project_environment(scope, project)}

  defp scope_for(%{active_project: %{id: id} = project} = scope, id),
    do: {:ok, with_project_environment(scope, project)}

  defp scope_for(scope, project_id) do
    case Projects.get_project(scope, project_id) do
      {:ok, project} ->
        {:ok,
         %{scope | active_project: project, active_project_id: project.id}
         |> with_project_environment(project)}

      _ ->
        :error
    end
  end

  defp with_project_environment(scope, nil), do: scope

  defp with_project_environment(%{environment: nil} = scope, project) do
    case Scope.for_local_project(project) do
      {:ok, %{environment: env, cwd: cwd}} -> %{scope | environment: env, cwd: cwd}
      _ -> scope
    end
  end

  defp with_project_environment(scope, _project), do: scope

  @impl true
  def handle_event("generate_project", _params, socket) do
    # Same call ProvisioningLive's "Generate deploy files" button made —
    # moved here, not reimplemented.
    scope = socket.assigns.current_scope
    project = scope.active_project

    case DeployArtifacts.generate(scope.environment,
           app: DeployArtifacts.otp_app_name(project),
           host: project.domain || "example.com",
           owner: System.get_env("GITHUB_SPEX_OWNER") || "your-org",
           registry: Provisioning.Registry.default_host(),
           image: registry_image(scope),
           kamal_image: registry_repository(scope),
           prod_registry: registry_address(scope, "prod"),
           uat_registry: registry_address(scope, "uat")
         ) do
      {:ok, []} ->
        {:noreply, put_flash(socket, :info, "Every deploy file is already in place.")}

      {:ok, written} ->
        {:noreply, put_flash(socket, :info, "Wrote #{Enum.join(written, ", ")}.")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Could not generate: #{inspect(reason)}")}
    end
  end

  def handle_event(
        "run_step_with_environment",
        %{"key" => key, "environment" => environment},
        socket
      )
      when is_binary(environment) and environment != "" do
    scope = socket.assigns.current_scope

    :ok =
      Provisioning.run_step_async(scope, String.to_existing_atom(key), environment: environment)

    {:noreply, put_flash(socket, :info, "Started.")}
  end

  defp registry_image(scope) do
    case Provisioning.Registry.image(scope) do
      {:ok, image} -> image
      _ -> nil
    end
  end

  defp registry_repository(scope) do
    case Provisioning.Registry.repository(scope) do
      {:ok, repository} -> repository
      _ -> nil
    end
  end

  defp registry_address(scope, environment) do
    case Provisioning.Steps.registry_address(scope, environment) do
      {:ok, address} -> address
      _ -> nil
    end
  end
end
