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

  Resources groups the plan's steps per `ResourceGroups` (servers, DNS and
  domain, mail in and out, storage and backups, publishing, feedback
  widget — plus repository, which the plan's own list doesn't name but
  dropping it would make it unreachable). Each group's ResourceDetail
  Config tab reuses the exact per-step components step 5 extracted
  (DnsConfig, DeployConfig, and so on), once per step key the group holds.
  Checks moves probes in one at a time behind `DiagnosticsPanel`, async via
  `start_async`/`handle_async` instead of the old page's blocking
  `phx-submit`. Storage's round-trip probe is converted (storage_backups'
  Checks tab); check_domain, content_publish, probe_restore and
  mail_inbound_probe still run exactly as they did on the old page —
  check_domain in particular is a multi-step search/purchase flow, not a
  single "run and read a result" diagnostic like the other four, so it
  needs its own look before it can follow the same pattern. Activity is
  still a placeholder.

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
  alias CodeMySpec.Provisioning.Steps
  alias CodeMySpec.Provisioning.Storage
  alias CodeMySpec.Provisioning.Teardown
  alias CodeMySpec.Users.Scope

  alias CodeMySpecWeb.ConsoleLive.Components.DiagnosticsPanel
  alias CodeMySpecWeb.ConsoleLive.Components.EnvironmentSwitcher
  alias CodeMySpecWeb.ConsoleLive.Components.ResourceDetail
  alias CodeMySpecWeb.ConsoleLive.Components.Sidebar
  alias CodeMySpecWeb.ConsoleLive.ResourceGroups
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
        # Same as ProvisioningLive.mount/3 — subscribed so a step's own
        # broadcast refreshes the plan once it changes, instead of the page
        # only finding out on the next patch. Not a "check": the run already
        # wrote the row, this just stops trusting a stale in-memory copy of
        # it (without this, a run's own state transitions were invisible
        # until something else happened to patch the URL).
        if connected?(socket), do: Provisioning.subscribe(scope)

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
    socket = refresh(socket)
    environments = socket.assigns.environments

    environment =
      params["env"] || Provisioning.primary_environment(scope) || List.first(environments)

    socket =
      socket
      |> assign(:environment, environment)
      |> assign(:resource_key, string_to_key(params["key"]))
      |> assign(:tab, params["tab"] || "config")
      |> assign_new(:credentials, fn -> Credentials.list(scope) end)
      |> assign_new(:missing_credentials, fn -> Credentials.missing(scope) end)
      |> assign_new(:secret_error, fn -> nil end)
      |> assign_new(:storage_ready?, fn -> Storage.credentials(scope, []) != :none end)
      |> assign_new(:storage_probe_running?, fn -> false end)
      |> assign_new(:storage_probe_result, fn -> nil end)

    {:noreply, socket}
  end

  # Everything `handle_params` reads straight from the scope rather than the
  # URL — the plan, the environment list and rows, who gets a secret. Pulled
  # out so an event that changes one of these (add/remove an environment)
  # can refresh the same way, without re-deriving `environment`/`resource_key`/
  # `tab` from params that have not changed.
  defp refresh(socket) do
    scope = socket.assigns.current_scope
    options = Provisioning.setup_options(scope)
    plan = Provisioning.plan(scope, options)
    environments = Provisioning.environment_names(scope)

    socket
    |> assign(:options, options)
    |> assign(:plan, plan)
    |> assign(:environments, environments)
    |> assign(:environment_rows, Provisioning.environments(scope))
    |> assign(:sops_recipients, Steps.recipients(scope, environments))
    |> assign(:secret_sources, secret_sources(environments))
  end

  # A made-up :key in the URL must read as "no such resource", not crash the
  # mount — to_existing_atom/1 raises on anything that was never a group key
  # anywhere in this running VM, which an arbitrary path segment from the
  # outside world absolutely can be.
  defp string_to_key(nil), do: nil

  defp string_to_key(key) do
    String.to_existing_atom(key)
  rescue
    ArgumentError -> nil
  end

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
          :for={{group, _steps, status} <- resource_groups(@plan, @environment)}
          navigate={
            ~p"/app/projects/#{@current_scope.active_project_id}/console/resources/#{group.key}?env=#{@environment}"
          }
          data-test="resource-card"
          data-resource={group.key}
          class="card bg-base-100 hover:shadow-md transition-shadow"
        >
          <div class="card-body p-4">
            <h3 class="card-title text-base">{group.label}</h3>
            <span class="badge badge-sm w-fit">{status}</span>
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
        :for={{group, steps, status} <- resource_groups(@plan, @environment)}
        navigate={
          ~p"/app/projects/#{@current_scope.active_project_id}/console/resources/#{group.key}?env=#{@environment}"
        }
        data-test="resource-row"
        data-resource={group.key}
        class="card bg-base-100 hover:shadow-md transition-shadow"
      >
        <div class="card-body p-4 flex-row items-center justify-between">
          <div>
            <h3 class="font-semibold">{group.label}</h3>
            <p class="text-sm opacity-70">{Enum.map_join(steps, ", ", & &1.label)}</p>
          </div>
          <span class="badge">{status}</span>
        </div>
      </.link>
    </section>
    """
  end

  defp render_section(%{live_action: :resource_detail} = assigns) do
    ~H"""
    <ResourceDetail.resource_detail
      group={ResourceGroups.get(@resource_key)}
      steps={resource_group_steps(@plan, @resource_key, @environment)}
      environments={@environments}
      age_key_environments={age_key_environments(@current_scope, @environments)}
      runs_in_flight?={Provisioning.runs_in_flight?(@current_scope)}
      tab={@tab}
      project_id={@current_scope.active_project_id}
      environment={@environment}
    >
      <:checks :if={@resource_key == :storage_backups && @storage_ready?}>
        <div data-test="storage-probe" data-state={storage_probe_state(assigns)}>
          <DiagnosticsPanel.diagnostics_panel
            title="Storage round-trip"
            checked_at={storage_probe_field(@storage_probe_result, :checked_at)}
          >
            <p class="opacity-70 text-sm">
              Writes an object and reads it back. A bucket that accepted a write
              is not the same as a bucket you can get your file out of again.
            </p>

            <form
              data-test="storage-probe-form"
              phx-submit="run_storage_probe"
              class="mt-3 flex flex-wrap gap-2 items-end"
            >
              <label class="form-control">
                <span class="label-text">Environment</span>
                <select name="probe[environment]" class="select select-bordered">
                  <option :for={environment <- @environments} value={environment}>
                    {environment}
                  </option>
                </select>
              </label>

              <label class="form-control">
                <span class="label-text">Key</span>
                <input name="probe[key]" value="probe.txt" class="input input-bordered" />
              </label>

              <label class="form-control">
                <span class="label-text">Content</span>
                <input name="probe[body]" value="hello" class="input input-bordered" />
              </label>

              <.button type="submit" data-test="run-storage-probe" disabled={@storage_probe_running?}>
                {if @storage_probe_running?, do: "Running…", else: "Write and read back"}
              </.button>
            </form>

            <ul class="mt-3 flex flex-col gap-1">
              <li
                :for={object <- storage_probe_field(@storage_probe_result, :objects) || []}
                data-test="storage-object"
                data-key={object.key}
                data-environment={object.environment}
                data-bucket={object.bucket}
              >
                wrote {object.key} to {object.bucket}
              </li>
            </ul>

            <ul class="mt-1 flex flex-col gap-1">
              <li
                :for={readback <- storage_probe_field(@storage_probe_result, :readbacks) || []}
                data-test="storage-readback"
                data-key={readback.key}
                data-environment={readback.environment}
                data-status={readback.status}
                data-matches-written={to_string(readback.matches)}
                data-reason={readback[:reason]}
              >
                read {readback.key} back: {readback.status}, matches {to_string(readback.matches)}
                <span :if={readback[:reason]} class="opacity-70">— {readback[:reason]}</span>
              </li>
            </ul>
          </DiagnosticsPanel.diagnostics_panel>
        </div>
      </:checks>
    </ResourceDetail.resource_detail>
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
        show_close?={false}
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
        show_close?={false}
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
        show_close?={false}
      />
    </section>
    """
  end

  defp setup_done_count(plan), do: Enum.count(plan, &(&1.state == :done))

  defp deploy_steps(plan, environment) do
    Enum.filter(plan, &(&1.key == :deploy and &1.environment == environment))
  end

  defp resource_groups(plan, environment) do
    for group <- ResourceGroups.all() do
      steps = ResourceGroups.steps(plan, group, environment)
      {group, steps, ResourceGroups.status(steps)}
    end
  end

  defp resource_group_steps(_plan, nil, _environment), do: []

  defp resource_group_steps(plan, key, environment) do
    case ResourceGroups.get(key) do
      nil -> []
      group -> ResourceGroups.steps(plan, group, environment)
    end
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
      Provisioning.run_step_async(
        scope,
        String.to_existing_atom(key),
        Keyword.put(step_opts(), :environment, environment)
      )

    {:noreply, put_flash(socket, :info, "Started.")}
  end

  # Same as ProvisioningLive.handle_event("run_step", ...) — the per-step
  # Run/Retry button ResourceDetail reuses from step 5's extraction carries
  # the same `phx-click="run_step"` contract, so it needs the same handler.
  # Missing this meant every Run/Retry click on the console crashed with no
  # matching clause; nothing in step 6's own smoke tests exercises the
  # button, so it went unnoticed until wiring the storage probe needed to
  # provision a bucket through it.
  def handle_event("run_step", %{"key" => key} = params, socket) do
    scope = socket.assigns.current_scope

    opts =
      case Map.get(params, "environment") do
        environment when is_binary(environment) and environment != "" ->
          Keyword.put(step_opts(), :environment, environment)

        _ ->
          step_opts()
      end

    :ok = Provisioning.run_step_async(scope, String.to_existing_atom(key), opts)

    {:noreply, put_flash(socket, :info, "Started.")}
  end

  # Manual, async, one result — not the old page's accumulating list. Sam
  # re-runs the probe to prove the bucket again, and that proof replaces the
  # last one rather than piling up; "checked … ago" is what makes a stale
  # result visible, not keeping every past attempt on screen.
  def handle_event("run_storage_probe", %{"probe" => probe}, socket) do
    scope = socket.assigns.current_scope
    environment = Map.get(probe, "environment", "prod")
    key = Map.get(probe, "key", "probe.txt")
    content = Map.get(probe, "body", "")

    socket =
      socket
      |> assign(:storage_probe_running?, true)
      |> start_async(:storage_probe, fn -> run_storage_probe(scope, environment, key, content) end)

    {:noreply, socket}
  end

  # Same as ProvisioningLive.handle_event("save_credentials", ...). The
  # Credentials section reuses `CredentialsForm` as-is, which still fires
  # this event — without a matching clause here the form submit crashed the
  # page, same gap "run_step" had.
  def handle_event("save_credentials", params, socket) do
    scope = socket.assigns.current_scope
    values = Map.get(params, "credentials", params)

    saved =
      Credentials.catalogue()
      |> Enum.filter(fn field ->
        field.kind == :secret and
          case Map.get(values, field.key) do
            value when is_binary(value) -> String.trim(value) != ""
            _ -> false
          end
      end)
      |> Enum.map(fn field ->
        Credentials.put_value(scope, field, String.trim(Map.fetch!(values, field.key)))
        field
      end)

    saved_keys = Enum.map(saved, & &1.key)
    saved_labels = Enum.map(saved, & &1.label)

    socket =
      case saved_labels do
        [] -> put_flash(socket, :info, "Nothing to save — every field was blank.")
        labels -> put_flash(socket, :info, "Saved #{Enum.join(labels, ", ")}.")
      end

    {:noreply,
     socket
     |> assign(:credentials, Credentials.list(scope, check: saved_keys))
     |> assign(:missing_credentials, Credentials.missing(scope))}
  end

  def handle_event("check_credentials", _params, socket) do
    scope = socket.assigns.current_scope

    {:noreply,
     socket
     |> assign(:credentials, Credentials.list(scope, check?: true))
     |> assign(:missing_credentials, Credentials.missing(scope))}
  end

  # Same as ProvisioningLive.handle_event("put_secret", ...) — SecretsForm's
  # own submit.
  def handle_event("put_secret", %{"secret" => params}, socket) do
    scope = socket.assigns.current_scope

    case Steps.put_secret(
           scope,
           params["environment"] || hd(socket.assigns.environments),
           String.trim(params["key"] || ""),
           params["value"] || ""
         ) do
      {:ok, %{key: key, environment: environment}} ->
        {:noreply,
         socket
         |> assign(:secret_error, nil)
         |> put_flash(:info, "Encrypted #{key} into #{environment}.")}

      {:error, reason} ->
        {:noreply, assign(socket, :secret_error, reason)}
    end
  end

  # Same as ProvisioningLive.handle_event("add_environment"/"remove_environment",
  # ...) — EnvironmentsForm's own submit and its confirm dialog's JS.push.
  # `refresh/1` instead of `load/2`: adding or removing an environment
  # changes the plan and the environment list, not the URL, so the same
  # recompute `handle_params` does on a patch has to happen here by hand.
  def handle_event("add_environment", %{"environment" => %{"name" => name}}, socket) do
    scope = socket.assigns.current_scope
    name = String.trim(name)

    if name == "" do
      {:noreply, put_flash(socket, :error, "an environment needs a name")}
    else
      case Provisioning.put_environment(scope, name) do
        {:ok, _environment} -> {:noreply, refresh(socket)}
        {:error, reason} -> {:noreply, put_flash(socket, :error, inspect(reason))}
      end
    end
  end

  def handle_event("remove_environment", %{"name" => name}, socket) do
    scope = socket.assigns.current_scope

    case Teardown.environment(scope, name) do
      {:ok, removed} ->
        {:noreply,
         socket
         |> put_flash(:info, removed_summary(name, removed))
         |> refresh()}

      {:error, {:left_behind, left}, removed} ->
        {:noreply,
         socket
         |> put_flash(
           :error,
           removed_summary(name, removed) <>
             " Still there, and worth removing by hand: " <>
             Enum.map_join(left, ", ", & &1.location)
         )
         |> refresh()}
    end
  end

  defp removed_summary(name, []), do: "Removed #{name}. It had nothing provisioned."

  defp removed_summary(name, removed),
    do: "Removed #{name}, and with it: " <> Enum.map_join(removed, ", ", & &1.location) <> "."

  defp step_opts, do: Application.get_env(:code_my_spec, :provisioning_step_opts, [])

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

  @impl true
  def handle_async(:storage_probe, {:ok, {:error, :no_credentials}}, socket) do
    {:noreply,
     socket
     |> assign(:storage_probe_running?, false)
     |> put_flash(:error, Storage.credentials_instructions())}
  end

  def handle_async(:storage_probe, {:ok, result}, socket) do
    {:noreply,
     socket
     |> assign(:storage_probe_running?, false)
     |> assign(:storage_probe_result, Map.put(result, :checked_at, DateTime.utc_now()))}
  end

  def handle_async(:storage_probe, {:exit, reason}, socket) do
    {:noreply,
     socket
     |> assign(:storage_probe_running?, false)
     |> put_flash(:error, "Storage probe crashed: #{inspect(reason)}")}
  end

  # Same as ProvisioningLive.handle_info({:provisioning, :step/:finished, ...}).
  # `refresh/1` instead of `load/2`: a broadcast only ever changes the plan
  # and the environment-derived state, never the URL-driven `environment`/
  # `resource_key`/`tab` assigns, so the cheaper recompute is the right one.
  @impl true
  def handle_info({:provisioning, :step, _row}, socket), do: {:noreply, refresh(socket)}
  def handle_info({:provisioning, :finished, _result}, socket), do: {:noreply, refresh(socket)}
  def handle_info(_message, socket), do: {:noreply, socket}

  defp storage_probe_state(%{storage_probe_running?: true}), do: "running"
  defp storage_probe_state(%{storage_probe_result: nil}), do: "unchecked"
  defp storage_probe_state(_assigns), do: "checked"

  defp storage_probe_field(nil, _key), do: nil
  defp storage_probe_field(result, key), do: Map.get(result, key)

  # Ported from ProvisioningLive.handle_event("storage_probe", ...) and its
  # private helpers (storage_probe/5, storage_readback/5, probe_failure/3) —
  # same round-trip, same data shape, run inside start_async instead of
  # inline in the handler so the page doesn't block on the provider call.
  defp run_storage_probe(scope, environment, key, content) do
    case Storage.credentials(scope, []) do
      :none ->
        {:error, :no_credentials}

      {:ok, credentials} ->
        bucket = Storage.bucket_name(scope.active_project, environment)
        {objects, readbacks} = storage_round_trip(bucket, key, content, credentials, environment)
        %{objects: objects, readbacks: readbacks}
    end
  end

  defp storage_round_trip(bucket, key, content, credentials, environment) do
    case Storage.put_object(bucket, key, content, credentials) do
      :ok ->
        object = %{key: key, environment: environment, bucket: bucket}
        {[object], [storage_readback(bucket, key, content, credentials, environment)]}

      {:error, reason} ->
        {[], [probe_failure(key, environment, reason)]}
    end
  end

  defp storage_readback(bucket, key, content, credentials, environment) do
    case Storage.get_object(bucket, key, credentials) do
      {:ok, ^content} ->
        %{key: key, environment: environment, status: "200", matches: true, reason: nil}

      {:ok, _other} ->
        %{key: key, environment: environment, status: "200", matches: false, reason: "bytes differ"}

      {:error, reason} ->
        probe_failure(key, environment, reason)
    end
  end

  defp probe_failure(key, environment, reason) do
    %{
      key: key,
      environment: environment,
      status: "error",
      matches: false,
      reason: format_probe_error(reason)
    }
  end

  defp format_probe_error(reason) when is_binary(reason), do: String.slice(reason, 0, 200)
  defp format_probe_error(reason), do: reason |> inspect() |> String.slice(0, 200)
end
