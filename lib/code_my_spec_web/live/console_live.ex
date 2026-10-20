defmodule CodeMySpecWeb.ConsoleLive do
  @moduledoc """
  The project console: provisioning, deploys, secrets, credentials and activity
  for one project. Reuses `ProvisioningLive.Components` and
  `ProvisioningLive.ResourceFields`; there is no separate provisioning page.

  ## Layout

  A right-hand sidebar (`drawer-end`): Overview, Resources, Deploys, Secrets,
  Credentials, Activity, Settings. Overview and Resources are scoped to the
  selected environment via `?env=` (patched, not navigated). Credentials,
  Secrets and Settings are project-wide. Deploys shows every environment's
  card side by side and has no switcher.

  ## Resources and checks

  Resources groups the plan's steps per `ResourceGroups` (plus repository).
  Each group's Config tab reuses the per-step components (DnsConfig,
  DeployConfig, ...). Checks run behind `DiagnosticsPanel` via `start_async`,
  each manual ("Run" / "checked … ago", one result, no auto-run). Domain
  search/purchase is a setup flow on DNS and domain's Config tab, not a check.

  ## Activity

  `CodeMySpec.Activity` is a persisted, append-only log. Every step trigger,
  check, credential save, secret write and environment edit records an entry,
  attributed via `Agents.actor/2`. Overview shows the last 10; the Activity tab
  everything, filterable by environment; a resource tab its own entries
  (`resource` matches `ResourceGroups.for_step/1`'s key).
  """

  use CodeMySpecWeb, :live_view

  alias CodeMySpec.Activity
  alias CodeMySpec.Generators.DeployArtifacts
  alias CodeMySpec.LocalScope
  alias CodeMySpec.Projects
  alias CodeMySpec.Provisioning
  alias CodeMySpec.Provisioning.Backups
  alias CodeMySpec.Provisioning.Cloudflare
  alias CodeMySpec.Provisioning.ContentPublishing
  alias CodeMySpec.Provisioning.Dns
  alias CodeMySpec.Provisioning.Resend
  alias CodeMySpec.Provisioning.Steps
  alias CodeMySpec.Provisioning.Storage
  alias CodeMySpec.Provisioning.Teardown
  alias CodeMySpec.Provisioning.Widget
  alias CodeMySpec.ProvisioningPlan.Sequence
  alias CodeMySpec.Resources
  alias CodeMySpec.Telemetry
  alias CodeMySpec.WorkingCopies

  alias CodeMySpecWeb.ConsoleLive.Components.DiagnosticsPanel
  alias CodeMySpecWeb.ConsoleLive.Components.EnvironmentSwitcher
  alias CodeMySpecWeb.ConsoleLive.Components.ResourceDetail
  alias CodeMySpecWeb.ConsoleLive.Components.SetupOptionsForm
  alias CodeMySpecWeb.ConsoleLive.Components.Shell
  alias CodeMySpecWeb.ConsoleLive.ResourceGroups
  alias CodeMySpecWeb.ProvisioningLive.Components.CredentialsForm
  alias CodeMySpecWeb.ProvisioningLive.Components.DeployConfig
  alias CodeMySpecWeb.ProvisioningLive.Components.EnvironmentsForm
  alias CodeMySpecWeb.ProvisioningLive.Components.SecretsForm

  alias CodeMySpec.Provisioning.Credentials

  @impl true
  def mount(params, _session, socket) do
    # The project in the URL, not whichever one happens to be active.
    case scope_for(socket.assigns.current_scope, params["project_id"]) do
      {:ok, scope} ->
        # A step's broadcast refreshes the plan; otherwise a run's own state
        # transitions stay invisible until the next patch.
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
      |> assign(:activity_environment, params["activity_env"])
      |> assign(:tab, params["tab"] || "config")
      |> assign_new(:credentials, fn -> Credentials.list(scope) end)
      |> assign_new(:missing_credentials, fn -> Credentials.missing(scope) end)
      |> assign_new(:secret_error, fn -> nil end)
      |> assign_new(:storage_ready?, fn -> Storage.credentials(scope, []) != :none end)
      |> assign_new(:storage_probe_running?, fn -> false end)
      |> assign_new(:storage_probe_result, fn -> nil end)
      |> assign_new(:restore_probe_running?, fn -> false end)
      |> assign_new(:restore_probe_result, fn -> nil end)
      |> assign_new(:content_publish_running?, fn -> false end)
      |> assign_new(:content_publish_result, fn -> nil end)
      |> assign_new(:mail_inbound_running?, fn -> false end)
      |> assign_new(:mail_inbound_result, fn -> nil end)
      |> assign_new(:domain_name, fn -> nil end)
      |> assign_new(:domain_check, fn -> nil end)
      |> assign_new(:domain_error, fn -> nil end)
      |> assign_new(:domain_check_running?, fn -> false end)
      |> assign_new(:domain_purchase_running?, fn -> false end)
      |> assign_new(:mail_send_running?, fn -> false end)
      |> assign_new(:mail_send_result, fn -> nil end)
      |> assign_new(:widget_degradation_running?, fn -> false end)
      |> assign_new(:widget_degradation, fn -> nil end)
      |> assign(
        :telemetry_check_running?,
        not is_nil(environment) and socket.assigns[:telemetry_check_environment] == environment
      )
      |> assign(:telemetry_check, Telemetry.last_check(scope, environment))
      # Each callback lists domains itself, so the Resend round-trip happens only
      # when a key is actually missing (assign_new is a no-op on later patches).
      |> assign_new(:mail, fn -> mail_state(scope, "prod", list_domains(scope)) end)
      |> assign_new(:mail_domains, fn -> mail_domains(scope, list_domains(scope)) end)
      |> assign_new(:backups, fn -> [] end)
      |> assign_new(:backup_health, fn -> nil end)

    {:noreply, socket}
  end

  # What `handle_params` reads from the scope rather than the URL (plan,
  # environments, secret recipients), so an event that changes them can refresh
  # without re-deriving the URL-driven assigns.
  defp refresh(socket) do
    scope = socket.assigns.current_scope
    options = Provisioning.setup_options(scope)
    plan = Provisioning.plan(scope, options)
    environments = Provisioning.environment_names(scope)

    socket
    |> assign(:options, options)
    |> assign(:plan, plan)
    |> assign(:runs_in_flight?, Provisioning.runs_in_flight?(scope))
    |> assign(:environments, environments)
    |> assign(:environment_rows, Provisioning.environments(scope))
    |> assign(:sops_recipients, Steps.recipients(scope, environments))
    |> assign(:secret_sources, secret_sources(environments))
    |> assign(:domain_registered, registered_domain(scope))
  end

  # An unknown :key in the URL is "no such resource", not a crash:
  # `to_existing_atom/1` raises on atoms the VM never saw.
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
      <Shell.frame project_id={@current_scope.active_project_id} active={@live_action}>
        <:toolbar>
          <EnvironmentSwitcher.environment_switcher
            :if={@live_action in [:overview, :resources, :resource_detail]}
            environment={@environment}
            environments={@environments}
            base_path={~p"/app/projects/#{@current_scope.active_project_id}/console"}
            live_action={@live_action}
          />
        </:toolbar>
        {render_section(assigns)}
      </Shell.frame>
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
              data-environment={step.environment}
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
          <p :if={overview_activity(@current_scope) == []} class="opacity-70 text-sm">
            Nothing yet.
          </p>
          <ul class="mt-2 flex flex-col gap-1">
            <li
              :for={entry <- overview_activity(@current_scope)}
              data-test="activity-entry"
              data-kind={entry.kind}
              data-resource={entry.resource}
              data-environment={entry.environment}
              data-actor={entry.actor}
              data-at={DateTime.to_iso8601(entry.inserted_at)}
              class="text-sm opacity-70"
            >
              {entry.summary} — {entry.actor}
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
      runs_in_flight?={@runs_in_flight?}
      tab={@tab}
      project_id={@current_scope.active_project_id}
      environment={@environment}
      activity_entries={resource_activity(@current_scope, @resource_key)}
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

      <:checks :if={@resource_key == :storage_backups}>
        <div data-test="restore-probe" data-state={restore_probe_state(assigns)}>
          <DiagnosticsPanel.diagnostics_panel
            title="Backup restore proof"
            checked_at={restore_probe_field(@restore_probe_result, :checked_at)}
          >
            <p class="opacity-70 text-sm">
              Restores the newest dump into a scratch database and counts the
              rows that came back — a restore exiting 0 over an empty dump is
              not proof of anything.
            </p>

            <.button
              data-test="backup-restore-probe"
              phx-click="run_restore_probe"
              class="btn btn-primary mt-2"
              disabled={@restore_probe_running?}
            >
              {if @restore_probe_running?, do: "Restoring…", else: "Restore the newest dump"}
            </.button>

            <div
              :if={@restore_probe_result}
              data-test="restore-result"
              data-state={@restore_probe_result.state}
              data-rows-restored={@restore_probe_result.rows}
              data-content-verified={to_string(@restore_probe_result.rows > 0)}
              data-target={Map.get(@restore_probe_result, :target)}
            >
              {if @restore_probe_result.state == "succeeded",
                do:
                  "restored #{@restore_probe_result.rows} rows into #{@restore_probe_result.target}",
                else: "restore failed: #{@restore_probe_result.reason}"}
            </div>
          </DiagnosticsPanel.diagnostics_panel>
        </div>
      </:checks>

      <:checks :if={@resource_key == :publishing}>
        <div data-test="content-publish-probe" data-state={content_publish_state(assigns)}>
          <DiagnosticsPanel.diagnostics_panel
            title="Publish and verify"
            checked_at={content_publish_field(@content_publish_result, :checked_at)}
          >
            <p class="opacity-70 text-sm">
              Snapshots, uploads, triggers a build, and fetches the post back
              from the live site — one command proving the whole pipeline,
              not just that a file landed somewhere.
            </p>

            <.button
              data-test="content-publish"
              phx-click="run_content_publish"
              class="btn btn-primary mt-3"
              disabled={@content_publish_running?}
            >
              {if @content_publish_running?, do: "Publishing…", else: "Publish the blog"}
            </.button>

            <div
              :if={@content_publish_result}
              data-test="content-publish-result"
              data-state={@content_publish_result.state}
              data-manual-steps-remaining={@content_publish_result.manual_steps_remaining}
              data-objects-uploaded={to_string(@content_publish_result.objects_uploaded)}
            >
              {@content_publish_result.summary}
              <span :if={@content_publish_result.error} data-test="content-publish-error">
                {@content_publish_result.error}
              </span>
            </div>
          </DiagnosticsPanel.diagnostics_panel>
        </div>
      </:checks>

      <:checks :if={@resource_key == :mail}>
        <div data-test="mail-inbound-probe-panel" data-state={mail_inbound_state(assigns)}>
          <DiagnosticsPanel.diagnostics_panel
            title="Inbound delivery"
            checked_at={mail_inbound_field(@mail_inbound_result, :checked_at)}
          >
            <p class="opacity-70 text-sm">
              Sends a message to this domain and waits for it to land in the
              app, not just a mailbox — a sending domain that cannot receive
              swallows every reply.
            </p>

            <%!-- A bare button, not a form — click_inbound_probe/1 (shared
                across story 974's spex) drives this with render_click's own
                value map, the same shape the old page's button took. --%>
            <.button
              data-test="mail-inbound-probe"
              phx-click="run_mail_inbound_probe"
              class="btn btn-primary mt-3"
              disabled={@mail_inbound_running?}
            >
              {if @mail_inbound_running?, do: "Sending…", else: "Send a message to this domain"}
            </.button>

            <div
              :if={@mail_inbound_result}
              data-test="inbound-delivery"
              data-state={@mail_inbound_result.state}
              data-destination={@mail_inbound_result.destination}
              data-message-id={@mail_inbound_result.message_id}
              data-completed-at={@mail_inbound_result.completed_at}
              data-delivered-to={@mail_inbound_result.delivered_to}
              data-body-available={to_string(@mail_inbound_result.body_available)}
              data-manual-forward={to_string(@mail_inbound_result.manual_forward)}
            >
              {@mail_inbound_result.summary}
            </div>
          </DiagnosticsPanel.diagnostics_panel>
        </div>
      </:checks>

      <:checks :if={@resource_key == :mail}>
        <div data-test="mail-send-probe-panel" data-state={mail_send_state(assigns)}>
          <DiagnosticsPanel.diagnostics_panel
            title="Outbound send"
            checked_at={mail_send_field(@mail_send_result, :checked_at)}
          >
            <p class="opacity-70 text-sm">
              Sends a real message and records what the provider accepted it
              from — a domain can verify and still refuse to send if the
              sending identity is wrong.
            </p>

            <.button
              data-test="mail-send-probe"
              phx-click="run_mail_send_probe"
              class="btn btn-primary mt-3"
              disabled={@mail_send_running?}
            >
              {if @mail_send_running?, do: "Sending…", else: "Send a test message"}
            </.button>

            <div
              :if={@mail_send_result}
              data-test="mail-send-result"
              data-from={@mail_send_result.from}
              data-accepted={to_string(@mail_send_result.accepted)}
              data-provider-id={@mail_send_result.provider_id}
              data-completed-at={@mail_send_result.completed_at}
              data-dkim={@mail_send_result.dkim}
              data-domain={@mail_send_result.domain}
              data-reason={@mail_send_result.reason}
            >
              sent from {@mail_send_result.from}: {if @mail_send_result.accepted,
                do: "accepted",
                else: "refused"}
              <span :if={@mail_send_result.reason}>— {@mail_send_result.reason}</span>
            </div>
          </DiagnosticsPanel.diagnostics_panel>
        </div>
      </:checks>

      <:checks :if={@resource_key == :widget}>
        <div data-test="widget-degradation-probe-panel" data-state={widget_degradation_state(assigns)}>
          <DiagnosticsPanel.diagnostics_panel
            title="Graceful degradation"
            checked_at={widget_degradation_field(@widget_degradation, :checked_at)}
          >
            <p class="opacity-70 text-sm">
              Asks the deployed site how it looks when the widget backend is
              gone — the claim is about the page staying usable, not about
              the widget itself.
            </p>

            <.button
              data-test="widget-degradation-probe"
              phx-click="run_widget_degradation_probe"
              class="btn btn-primary mt-3"
              disabled={@widget_degradation_running?}
            >
              {if @widget_degradation_running?,
                do: "Checking…",
                else: "Check the site with the widget backend down"}
            </.button>

            <div
              :if={@widget_degradation}
              data-test="widget-degradation-result"
              data-page-status={@widget_degradation.page_status}
              data-page-usable={to_string(@widget_degradation.page_usable)}
              data-widget-state={@widget_degradation.widget_state}
            >
              {@widget_degradation.summary}
            </div>
          </DiagnosticsPanel.diagnostics_panel>
        </div>
      </:checks>

      <:checks :if={@resource_key == :telemetry}>
        <div data-test="telemetry-check-panel" data-state={telemetry_check_state(assigns)}>
          <DiagnosticsPanel.diagnostics_panel
            title="Telemetry"
            checked_at={telemetry_check_field(@telemetry_check, :checked_at)}
          >
            <p class="opacity-70 text-sm">
              Checks the collector host over HTTPS, that the read-only login
              can read, and that it cannot write.
            </p>

            <.button
              data-test="run-check"
              data-check="telemetry"
              phx-click="run_telemetry_check"
              class="btn btn-primary mt-3"
              disabled={@telemetry_check_running?}
            >
              {if @telemetry_check_running?, do: "Checking…", else: "Check"}
            </.button>

            <div
              :if={@telemetry_check}
              data-test="telemetry-check-result"
              data-reachable={to_string(@telemetry_check.reachable)}
              data-reads={to_string(@telemetry_check.reads)}
              data-writes={to_string(@telemetry_check.writes)}
              class="mt-4 space-y-2 text-sm"
              role="status"
              aria-live="polite"
            >
              <p>
                <span class="font-semibold">HTTPS reachability:</span>
                {case @telemetry_check.reachable do
                  true -> "Reachable"
                  false -> "Unavailable — check telemetry setup, DNS, TLS, and server connectivity."
                end}
              </p>
              <p>
                <span class="font-semibold">Read access:</span>
                {case {@telemetry_check.reachable, @telemetry_check.reads} do
                  {_, :ok} -> "Working"
                  {false, :error} -> "Could not verify while telemetry is unavailable."
                  {true, :error} -> "Failed — check the reader credentials and table permissions."
                end}
              </p>
              <p>
                <span class="font-semibold">Write protection:</span>
                {case @telemetry_check.writes do
                  :refused ->
                    "Working — writes refused for the read-only login."

                  :ok ->
                    "Unsafe — writes are allowed. Remove write permissions from the reader login."

                  :error ->
                    "Could not verify — restore connectivity and read access, then check again."
                end}
              </p>
            </div>
          </DiagnosticsPanel.diagnostics_panel>
        </div>
      </:checks>

      <:mail_panel :if={@resource_key == :mail}>
        <section :if={@mail} data-test="mail" class="my-6">
          <h2 class="text-lg font-semibold">Outbound mail</h2>

          <div
            :for={entry <- @mail_domains}
            data-test="mail-sending-domain"
            data-domain={entry.domain}
            data-name={entry.domain}
            data-environment={entry.environment}
            data-status={entry.status}
            data-provider-id={entry.provider_id}
            data-manual-step-required={to_string(entry.manual_step_required)}
            data-verified-separately={to_string(entry.status == "verified")}
          >
            {entry.environment}: {entry.domain} — {entry.status}
          </div>

          <div
            data-test="mail-verification"
            data-status={@mail.status}
            data-attempts={@mail.attempts}
            data-verified-at={@mail.verified_at}
            data-dkim={@mail.dkim}
            data-manual-step-required={to_string(@mail.manual_step_required)}
          >
            verification: {@mail.status} after {@mail.attempts} check(s)
          </div>

          <ul class="mt-2 flex flex-col gap-1">
            <li
              :for={record <- @mail.records}
              data-test="mail-dns-record"
              data-type={record.type}
              data-name={record.name}
              data-verified={to_string(record.verified)}
              data-resolved={to_string(record.resolved)}
              data-content={record.content}
            >
              {record.type} {record.name} — {if record.verified, do: "verified", else: "pending"}
            </li>
          </ul>

          <div
            :if={@mail.missing_records != []}
            data-test="dns-record-deleted"
            data-name={List.first(@mail.missing_records)}
          >
            a record this domain needs is no longer published: {Enum.join(
              @mail.missing_records,
              ", "
            )}
          </div>

          <.button data-test="dns-refresh" phx-click="refresh_mail_dns" class="btn btn-primary mt-2">
            Re-check DNS
          </.button>
        </section>
      </:mail_panel>

      <:backups_panel :if={@resource_key == :storage_backups}>
        <section data-test="backups-panel">
          <h2 class="text-lg font-semibold">Backups</h2>

          <.button
            data-test="backups-refresh"
            phx-click="refresh_backups"
            class="btn btn-primary mt-2"
          >
            Check the bucket
          </.button>

          <p :if={@backups == []} data-test="no-backups">
            no dumps in any bucket yet
          </p>

          <%!-- A backup that stopped running looks exactly like one that is
              working, right up until somebody needs it. "never" and "stalled"
              are reported apart because "it never ran" and "it stopped last
              Tuesday" send Sam to different places. --%>
          <div
            :if={@backup_health}
            data-test="backup-health"
            data-state={@backup_health.state}
            data-last-successful-at={@backup_health.last_seen}
            data-stale-after-hours={@backup_health.stale_after_hours}
          >
            {case @backup_health.state do
              "healthy" -> "backups are landing (newest #{@backup_health.last_seen})"
              "stalled" -> "backups have stopped landing — newest is #{@backup_health.last_seen}"
              "never" -> "no dump has ever landed"
            end}
          </div>

          <div
            :for={dump <- @backups}
            data-test="backup-dump"
            data-key={dump.key}
            data-environment={dump.environment}
            data-bucket={dump.bucket}
            data-taken-at={dump.taken_at}
            data-age-days={dump.age_days}
            data-size={dump.size}
          >
            {dump.environment}: {dump.key} ({dump.taken_at})
          </div>
        </section>
      </:backups_panel>

      <:domain_search :if={@resource_key == :dns_domain}>
        <section data-test="domain" data-state={domain_search_state(assigns)} class="my-6">
          <h2 class="text-lg font-semibold">Domain</h2>
          <p class="opacity-70 text-sm">
            Bring a domain you already own and check it here to adopt it. To register a new
            one, buy it in the Cloudflare dashboard and come back — the Registrar API will
            not price or sell a name this app does not already hold.
          </p>

          <form
            data-test="domain-form"
            phx-submit="check_domain"
            class="mt-3 flex gap-2 items-end"
          >
            <label class="form-control">
              <span class="label-text text-xs">Domain</span>
              <input
                type="text"
                name="domain[name]"
                value={@domain_name}
                class="input input-bordered input-sm"
                placeholder="example.com"
              />
            </label>
            <.button type="submit" data-test="check-domain" disabled={@domain_check_running?}>
              {if @domain_check_running?, do: "Checking…", else: "Check"}
            </.button>
          </form>

          <div :if={@domain_check} class="mt-3 flex flex-col gap-2">
            <span
              data-test="domain-availability"
              data-availability={to_string(@domain_check.availability)}
              data-available={to_string(@domain_check.availability == :available)}
              data-supported-tld={to_string(@domain_check.supported_tld)}
              data-name={@domain_name}
              class={[
                "badge",
                @domain_check.availability == :available && "badge-success",
                @domain_check.availability == :taken && "badge-error"
              ]}
            >
              {availability_label(@domain_check)}
            </span>

            <p :if={@domain_check.availability == :taken} data-test="domain-taken" class="text-sm">
              {@domain_name} is already registered{if @domain_check.current_registrar,
                do: " (#{@domain_check.current_registrar})"}. Pick another name.
            </p>

            <span
              :if={@domain_check.availability == :available and @domain_check.price}
              data-test="domain-price"
              class="text-sm"
            >
              {@domain_check.price} {@domain_check.currency}
            </span>

            <.button
              :if={@domain_check.availability == :available and @domain_check.price}
              data-test="confirm-purchase"
              phx-click="confirm_purchase"
              class="btn btn-warning w-fit"
              disabled={@domain_purchase_running?}
            >
              {if @domain_purchase_running?,
                do: "Registering…",
                else: "Yes — register #{@domain_name}"}
            </.button>

            <div
              :if={
                @domain_check.supported_tld and @domain_check.availability != :available and
                  @domain_check.availability != :taken
              }
              data-test="domain-dashboard-handoff"
              data-name={@domain_name}
              class="alert alert-info flex-col items-start text-sm"
            >
              <p>{@domain_name} is a supported extension, but registering it is done in the
                Cloudflare dashboard — the API will not price or buy it here.</p>
              <a
                href="https://dash.cloudflare.com/?to=/:account/domains/register"
                target="_blank"
                rel="noopener"
                data-test="domain-dashboard-link"
                class="link"
              >Register it in the Cloudflare dashboard</a>, then re-check to adopt it.
            </div>

            <div
              :if={not @domain_check.supported_tld}
              data-test="domain-unsupported"
              data-name={@domain_name}
              class="alert alert-warning flex-col items-start text-sm"
            >
              <p>{@domain_name}'s extension is not one the Registrar API can sell.</p>
              <a
                href="https://dash.cloudflare.com/?to=/:account/domains/register"
                target="_blank"
                rel="noopener"
                data-test="domain-dashboard-link"
                class="link"
              >Register it in the Cloudflare dashboard</a>, then re-check to adopt it.
            </div>
          </div>

          <div
            :if={@domain_registered}
            data-test="domain-registered"
            data-name={@domain_registered.name}
            data-adopted={to_string(@domain_registered.adopted)}
            data-owned-already={to_string(@domain_registered.adopted)}
            class="mt-3 badge badge-outline"
          >
            {@domain_registered.name} {if @domain_registered.adopted,
              do: "(already yours)",
              else: "registered"}
          </div>

          <p :if={@domain_error} data-test="domain-error" class="text-error text-xs mt-2">
            {@domain_error}
          </p>
        </section>
      </:domain_search>
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
        :for={step <- deploy_steps(@plan)}
        data-test="deploy-row"
        data-step={step.key}
        data-environment={step.environment}
        data-state={step.state}
        data-completed-at={step_completed_at(step)}
        data-started-at={step_started_at(step)}
        data-verified-at={step_verified_at(step)}
        class="card bg-base-100"
      >
        <div class="card-body">
          <h3 class="card-title text-base">
            Deploy {step.environment} <span class="badge">{step.state}</span>
          </h3>
          <DeployConfig.deploy_config
            step={step}
            age_key_environments={age_key_environments(@current_scope, @environments)}
            runs_in_flight?={@runs_in_flight?}
          />
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
    <section data-test="console-activity-page" class="flex flex-col gap-4">
      <div data-test="activity-env-filter" role="tablist" class="tabs tabs-boxed w-fit">
        <.link
          patch={~p"/app/projects/#{@current_scope.active_project_id}/console/activity"}
          data-test="activity-filter-option"
          data-environment="all"
          role="tab"
          class={["tab", is_nil(@activity_environment) && "tab-active"]}
        >
          All
        </.link>
        <.link
          :for={env <- @environments}
          patch={
            ~p"/app/projects/#{@current_scope.active_project_id}/console/activity?activity_env=#{env}"
          }
          data-test="activity-filter-option"
          data-environment={env}
          role="tab"
          class={["tab", @activity_environment == env && "tab-active"]}
        >
          {env}
        </.link>
      </div>

      <div class="flex flex-col gap-1">
        <p
          :if={activity_feed(@current_scope, @activity_environment) == []}
          class="opacity-70 text-sm"
        >
          Nothing yet.
        </p>
        <div
          :for={entry <- activity_feed(@current_scope, @activity_environment)}
          data-test="activity-entry"
          data-kind={entry.kind}
          data-resource={entry.resource}
          data-environment={entry.environment}
          data-actor={entry.actor}
          data-at={DateTime.to_iso8601(entry.inserted_at)}
          class="text-sm opacity-70 border-b border-base-200 py-1"
        >
          {entry.summary} — {entry.actor}
        </div>
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

      <SetupOptionsForm.setup_options_form options={@options} />
    </section>
    """
  end

  defp setup_done_count(plan), do: Enum.count(plan, &(&1.state == :done))

  defp setup_option_summary(option, updated) do
    if option in updated, do: "enabled #{option}", else: "disabled #{option}"
  end

  # Every environment's deploy, not just the switcher's: Deploys ships to any.
  defp deploy_steps(plan) do
    Enum.filter(plan, &(&1.key == :deploy))
  end

  # Same as ResourceDetail's copies; small enough to duplicate.
  defp step_completed_at(%{state: :done, completed_at: %DateTime{} = at}),
    do: DateTime.to_iso8601(at)

  defp step_completed_at(_step), do: nil

  defp step_started_at(%{started_at: %DateTime{} = at}), do: DateTime.to_iso8601(at)
  defp step_started_at(_step), do: nil

  defp step_verified_at(%{verified_at: %DateTime{} = at}), do: DateTime.to_iso8601(at)
  defp step_verified_at(_step), do: nil

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

  defp overview_activity(scope) do
    scope |> Activity.list_for_project() |> Enum.take(10)
  end

  defp activity_feed(scope, environment),
    do: Activity.list_for_project(scope, environment: environment)

  defp resource_activity(_scope, nil), do: []
  defp resource_activity(scope, key), do: Activity.list_for_resource(scope, key)

  defp scope_for(%{active_project: %{} = project} = scope, nil),
    do: {:ok, Resources.project_scope(scope, project)}

  defp scope_for(%{active_project: %{id: id} = project} = scope, id),
    do: {:ok, Resources.project_scope(scope, project)}

  defp scope_for(scope, project_id) do
    case Projects.get_project(scope, project_id) do
      {:ok, project} ->
        {:ok, Resources.project_scope(scope, project)}

      _ ->
        :error
    end
  end

  # Resolve the checkout at the operation boundary; caller identity supplies
  # authorization, not the execution environment.
  defp operation_environment(%{active_working_copy_id: id} = scope) when not is_nil(id),
    do: WorkingCopies.environment(scope)

  defp operation_environment(scope), do: LocalScope.environment(scope.active_project)

  @impl true
  def handle_event("generate_project", _params, socket) do
    scope = socket.assigns.current_scope
    project = scope.active_project

    case DeployArtifacts.generate(operation_environment(scope),
           app: DeployArtifacts.otp_app_name(project),
           host: project.domain || "example.com",
           owner: System.get_env("GITHUB_SPEX_OWNER") || "your-org",
           registry: Provisioning.Registry.default_host(),
           image: registry_image(scope),
           kamal_image: registry_repository(scope),
           prod_registry: registry_address(scope, "prod"),
           uat_registry: registry_address(scope, "uat"),
           telemetry_host: "telemetry.#{project.domain || "example.com"}"
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
    opts = Keyword.put(step_opts(), :environment, environment)

    {:noreply,
     socket
     |> run_step_and_log(String.to_existing_atom(key), opts)
     |> put_flash(:info, "Started.")}
  end

  # The per-step Run/Retry button in ResourceDetail fires `run_step`.
  def handle_event("run_step", %{"key" => key} = params, socket) do
    opts =
      case Map.get(params, "environment") do
        environment when is_binary(environment) and environment != "" ->
          Keyword.put(step_opts(), :environment, environment)

        _ ->
          step_opts()
      end

    {:noreply,
     socket
     |> run_step_and_log(String.to_existing_atom(key), opts)
     |> put_flash(:info, "Started.")}
  end

  # Manual, async, one result: a re-run replaces the last proof, and "checked …
  # ago" shows staleness.
  def handle_event("run_storage_probe", %{"probe" => probe}, socket) do
    scope = socket.assigns.current_scope
    environment = Map.get(probe, "environment", "prod")
    key = Map.get(probe, "key", "probe.txt")
    content = Map.get(probe, "body", "")

    Activity.record(scope, "check", "storage_backups", "ran the storage probe",
      environment: environment
    )

    socket =
      socket
      |> assign(:storage_probe_running?, true)
      |> start_async(:storage_probe, fn -> run_storage_probe(scope, environment, key, content) end)

    {:noreply, socket}
  end

  # Same manual/async/one-result shape as `run_storage_probe`.
  def handle_event("run_restore_probe", _params, socket) do
    scope = socket.assigns.current_scope
    environment = operation_environment(scope)
    options = socket.assigns.options

    Activity.record(scope, "check", "storage_backups", "ran the restore probe")

    socket =
      socket
      |> assign(:restore_probe_running?, true)
      |> start_async(:restore_probe, fn -> run_restore_probe(scope, environment, options) end)

    {:noreply, socket}
  end

  def handle_event("run_content_publish", _params, socket) do
    scope = socket.assigns.current_scope
    opts = publish_opts(scope)

    socket =
      socket
      |> assign(:content_publish_running?, true)
      |> start_async(:content_publish, fn -> run_content_publish(scope, opts) end)

    {:noreply, socket}
  end

  # A bare button: `to` arrives as `params["to"]`, not nested under a form name.
  def handle_event("run_mail_inbound_probe", params, socket) do
    scope = socket.assigns.current_scope
    domain = scope.active_project.domain

    to =
      case Map.get(params, "to") do
        address when is_binary(address) and address != "" -> address
        _ -> default_inbound_address(scope, domain)
      end

    Activity.record(scope, "check", "mail", "ran the inbound mail probe")

    socket =
      socket
      |> assign(:mail_inbound_running?, true)
      |> start_async(:mail_inbound_probe, fn -> run_mail_inbound_probe(scope, to) end)

    {:noreply, socket}
  end

  # Domain search/purchase is a setup flow on DNS and domain's Config tab, not a
  # check. Cloudflare calls run in `start_async`: both can block on the registrar.
  def handle_event("check_domain", %{"domain" => %{"name" => name}}, socket) do
    name = String.trim(name)
    scope = socket.assigns.current_scope

    socket =
      socket
      |> assign(:domain_check_running?, true)
      |> start_async(:domain_check, fn -> run_domain_check(scope, name) end)

    {:noreply, socket}
  end

  def handle_event("confirm_purchase", _params, socket) do
    scope = socket.assigns.current_scope
    name = socket.assigns.domain_name

    socket =
      socket
      |> assign(:domain_purchase_running?, true)
      |> start_async(:domain_purchase, fn -> run_domain_purchase(scope, name) end)

    {:noreply, socket}
  end

  # Same manual/async/one-result shape as the other probes.
  def handle_event("run_mail_send_probe", params, socket) do
    scope = socket.assigns.current_scope
    probe = Map.get(params, "probe", %{})
    to = Map.get(probe, "to", "delivered@resend.dev")
    environment = Map.get(probe, "environment", "prod")

    Activity.record(scope, "check", "mail", "ran the outbound mail probe",
      environment: environment
    )

    socket =
      socket
      |> assign(:mail_send_running?, true)
      |> start_async(:mail_send_probe, fn -> run_mail_send_probe(scope, to, environment) end)

    {:noreply, socket}
  end

  # A Config action, not a check: re-reads the outbound mail panel's state.
  def handle_event("refresh_mail_dns", _params, socket) do
    {:noreply, refresh_mail(socket)}
  end

  # A Config action: re-reads whether scheduled dumps are still landing.
  def handle_event("refresh_backups", _params, socket) do
    scope = socket.assigns.current_scope
    dumps = list_backups(scope, socket.assigns.options)

    {:noreply,
     socket
     |> assign(:backups, dumps)
     |> assign(:backup_health, Backups.health(dumps, step_opts()))}
  end

  def handle_event("run_widget_degradation_probe", _params, socket) do
    scope = socket.assigns.current_scope
    site = site_url(scope.active_project.domain)

    Activity.record(scope, "check", "widget", "ran the widget degradation probe")

    socket =
      socket
      |> assign(:widget_degradation_running?, true)
      |> start_async(:widget_degradation_probe, fn ->
        widget_degradation(site && Widget.probe_degraded(site, []))
      end)

    {:noreply, socket}
  end

  def handle_event("run_telemetry_check", _params, socket) do
    scope = socket.assigns.current_scope
    environment = socket.assigns.environment
    opts = step_opts()

    socket =
      socket
      |> assign(:telemetry_check_running?, true)
      |> assign(:telemetry_check_environment, environment)
      |> start_async(:telemetry_check, fn ->
        {environment, Telemetry.check(scope, environment, opts)}
      end)

    {:noreply, socket}
  end

  # `CredentialsForm`'s submit.
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
        [] ->
          put_flash(socket, :info, "Nothing to save — every field was blank.")

        labels ->
          # Labels only: values are credentials and never reach the log.
          Activity.record(
            scope,
            "credential_save",
            "credentials",
            "saved #{Enum.join(labels, ", ")}"
          )

          put_flash(socket, :info, "Saved #{Enum.join(labels, ", ")}.")
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

  # `SecretsForm`'s submit.
  def handle_event("put_secret", %{"secret" => params}, socket) do
    scope = socket.assigns.current_scope

    case Steps.put_secret(
           scope,
           params["environment"] || hd(socket.assigns.environments),
           String.trim(params["key"] || ""),
           params["value"] || ""
         ) do
      {:ok, %{key: key, environment: environment}} ->
        # The name, never the value.
        Activity.record(scope, "secret_write", "secrets", "wrote secret #{key}",
          environment: environment
        )

        {:noreply,
         socket
         |> assign(:secret_error, nil)
         |> put_flash(:info, "Encrypted #{key} into #{environment}.")}

      {:error, reason} ->
        {:noreply, assign(socket, :secret_error, reason)}
    end
  end

  # `SecretsForm`'s bulk-import submit -- the real path to bring an app's
  # existing secrets into sops rather than retyping them one at a time, or
  # letting a later step mint fresh ones over values that already exist.
  def handle_event("import_secrets", %{"import" => params}, socket) do
    scope = socket.assigns.current_scope
    environment = params["environment"] || hd(socket.assigns.environments)

    case Steps.import_dotenv(scope, environment, params["dotenv"] || "") do
      {:ok, keys} ->
        # The names, never the values.
        Activity.record(
          scope,
          "secret_write",
          "secrets",
          "imported #{length(keys)} secret(s): #{Enum.join(keys, ", ")}",
          environment: environment
        )

        {:noreply,
         socket
         |> assign(:secret_error, nil)
         |> put_flash(:info, "Imported #{length(keys)} secret(s) into #{environment}.")}

      {:error, reason} ->
        {:noreply, assign(socket, :secret_error, reason)}
    end
  end

  # `EnvironmentsForm`'s submit and its confirm dialog's push. `refresh/1`: the
  # plan and environment list change, not the URL.
  def handle_event("add_environment", %{"environment" => %{"name" => name}}, socket) do
    scope = socket.assigns.current_scope
    name = String.trim(name)

    if name == "" do
      {:noreply, put_flash(socket, :error, "an environment needs a name")}
    else
      case Provisioning.put_environment(scope, name) do
        {:ok, _environment} ->
          Activity.record(scope, "environment_edit", "settings", "added environment #{name}",
            environment: name
          )

          {:noreply, refresh(socket)}

        {:error, reason} ->
          {:noreply, put_flash(socket, :error, inspect(reason))}
      end
    end
  end

  # `refresh/1`: toggling an option changes the plan, not the URL.
  def handle_event("toggle_setup_option", %{"option" => option}, socket) do
    scope = socket.assigns.current_scope

    case string_to_key(option) do
      nil ->
        {:noreply, socket}

      option ->
        current = socket.assigns.options
        updated = if option in current, do: List.delete(current, option), else: [option | current]

        case Provisioning.put_setup_options(scope, updated) do
          {:ok, project} ->
            Activity.record(
              scope,
              "setup_options_edit",
              "settings",
              setup_option_summary(option, updated)
            )

            {:noreply,
             socket
             |> assign(:current_scope, %{scope | active_project: project})
             |> refresh()}

          {:error, reason} ->
            {:noreply, put_flash(socket, :error, inspect(reason))}
        end
    end
  end

  def handle_event("remove_environment", %{"name" => name}, socket) do
    scope = socket.assigns.current_scope

    case Teardown.environment(scope, name) do
      {:ok, removed} ->
        Activity.record(scope, "environment_edit", "settings", "removed environment #{name}",
          environment: name
        )

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

  # Fired by DnsConfig/RepositoryConfig's paused-step confirmations. The step's
  # own row carries its state; there is no whole-sequence run to halt here.
  def handle_event("confirm_apex_repoint", _params, socket) do
    {:noreply, run_step_and_log(socket, :dns, step_opts() ++ [confirm_apex_repoint: true])}
  end

  def handle_event("confirm_inbound_mx_repoint", _params, socket) do
    {:noreply,
     run_step_and_log(socket, :inbound, step_opts() ++ [confirm_inbound_mx_repoint: true])}
  end

  def handle_event("adopt_repository", %{"owner" => owner, "name" => name}, socket) do
    owner = String.trim(owner)
    name = String.trim(name)

    if Regex.match?(~r/\A[A-Za-z0-9-]+\z/, owner) and
         Regex.match?(~r/\A[A-Za-z0-9_.-]+\z/, name) and name not in [".", ".."] do
      opts = Keyword.merge(step_opts(), owner: owner, name: name, adopt: true)
      {:noreply, run_step_and_log(socket, :repository, opts)}
    else
      {:noreply, put_flash(socket, :error, "Enter a GitHub owner and repository name.")}
    end
  end

  def handle_event("adopt_repository", _params, socket) do
    {:noreply, run_step_and_log(socket, :repository, step_opts() ++ [adopt: true])}
  end

  def handle_event("rename_repository", _params, socket) do
    {:noreply,
     push_navigate(socket,
       to: ~p"/app/projects/#{socket.assigns.current_scope.active_project.id}/edit"
     )}
  end

  def handle_event("run_step_with_probe_address", %{"key" => key, "probe_to" => address}, socket)
      when is_binary(address) and address != "" do
    {:noreply,
     run_step_and_log(
       socket,
       String.to_existing_atom(key),
       [inbound_probe_to: address] ++ step_opts()
     )}
  end

  defp removed_summary(name, []), do: "Removed #{name}. It had nothing provisioned."

  defp removed_summary(name, removed),
    do: "Removed #{name}, and with it: " <> Enum.map_join(removed, ", ", & &1.location) <> "."

  defp step_opts, do: Application.get_env(:code_my_spec, :provisioning_step_opts, [])

  # Every step trigger goes through here so the activity log and the run cannot
  # drift. Logged on trigger, not on the async result: the row is the state.
  defp run_step_and_log(socket, key, opts) do
    scope = socket.assigns.current_scope
    environment = activity_environment(key, opts, socket)

    :ok = Provisioning.run_step_async(scope, key, opts)

    Activity.record(scope, kind_for_step(key), resource_for_step(key), "ran the #{key} step",
      environment: environment
    )

    socket
  end

  defp kind_for_step(:deploy), do: "deploy"
  defp kind_for_step(_key), do: "provision"

  defp resource_for_step(:deploy), do: "deploys"
  defp resource_for_step(key), do: ResourceGroups.for_step(key)

  defp activity_environment(:deploy, opts, _socket), do: Keyword.get(opts, :environment)

  defp activity_environment(key, _opts, socket) do
    case Sequence.scope(key) do
      :project -> nil
      :environment -> socket.assigns[:environment]
    end
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

  def handle_async(:restore_probe, {:ok, result}, socket) do
    {:noreply,
     socket
     |> assign(:restore_probe_running?, false)
     |> assign(:restore_probe_result, Map.put(result, :checked_at, DateTime.utc_now()))}
  end

  def handle_async(:restore_probe, {:exit, reason}, socket) do
    {:noreply,
     socket
     |> assign(:restore_probe_running?, false)
     |> put_flash(:error, "Restore probe crashed: #{inspect(reason)}")}
  end

  def handle_async(:content_publish, {:ok, result}, socket) do
    {:noreply,
     socket
     |> assign(:content_publish_running?, false)
     |> assign(:content_publish_result, Map.put(result, :checked_at, DateTime.utc_now()))}
  end

  def handle_async(:content_publish, {:exit, reason}, socket) do
    {:noreply,
     socket
     |> assign(:content_publish_running?, false)
     |> put_flash(:error, "Publish crashed: #{inspect(reason)}")}
  end

  def handle_async(:mail_inbound_probe, {:ok, result}, socket) do
    {:noreply,
     socket
     |> assign(:mail_inbound_running?, false)
     |> assign(:mail_inbound_result, Map.put(result, :checked_at, DateTime.utc_now()))}
  end

  def handle_async(:mail_inbound_probe, {:exit, reason}, socket) do
    {:noreply,
     socket
     |> assign(:mail_inbound_running?, false)
     |> put_flash(:error, "Inbound probe crashed: #{inspect(reason)}")}
  end

  def handle_async(:domain_check, {:ok, {:adopt, name}}, socket) do
    socket =
      socket
      |> assign(:domain_check_running?, false)
      |> assign(domain_name: name, domain_check: nil, domain_error: nil)
      |> adopt_domain(name)

    {:noreply, socket}
  end

  def handle_async(:domain_check, {:ok, {:checked, name, check}}, socket) do
    {:noreply,
     socket
     |> assign(:domain_check_running?, false)
     |> assign(domain_name: name, domain_check: check, domain_error: nil)}
  end

  def handle_async(:domain_check, {:ok, {:check_failed, name, reason}}, socket) do
    {:noreply,
     socket
     |> assign(:domain_check_running?, false)
     |> assign(domain_name: name, domain_check: nil, domain_error: describe_domain_error(reason))}
  end

  def handle_async(:domain_check, {:exit, reason}, socket) do
    {:noreply,
     socket
     |> assign(:domain_check_running?, false)
     |> put_flash(:error, "Domain check crashed: #{inspect(reason)}")}
  end

  def handle_async(:domain_purchase, {:ok, {:adopt, name}}, socket) do
    socket =
      socket
      |> assign(:domain_purchase_running?, false)
      |> assign(:domain_check, nil)
      |> adopt_domain(name)

    {:noreply, socket}
  end

  def handle_async(:domain_purchase, {:ok, {:register, name}}, socket) do
    socket =
      socket
      |> assign(:domain_purchase_running?, false)
      |> assign(domain_check: nil, domain_error: nil)
      |> register_domain_on_project(name, false)

    {:noreply, socket}
  end

  def handle_async(:domain_purchase, {:ok, {:paused, message}}, socket) do
    {:noreply,
     socket
     |> assign(:domain_purchase_running?, false)
     |> assign(domain_check: nil, domain_error: message)}
  end

  def handle_async(:domain_purchase, {:ok, {:purchase_failed, reason}}, socket) do
    {:noreply,
     socket
     |> assign(:domain_purchase_running?, false)
     |> assign(:domain_error, describe_domain_error(reason))}
  end

  def handle_async(:domain_purchase, {:exit, reason}, socket) do
    {:noreply,
     socket
     |> assign(:domain_purchase_running?, false)
     |> put_flash(:error, "Domain purchase crashed: #{inspect(reason)}")}
  end

  def handle_async(:mail_send_probe, {:ok, result}, socket) do
    {:noreply,
     socket
     |> assign(:mail_send_running?, false)
     |> assign(:mail_send_result, Map.put(result, :checked_at, DateTime.utc_now()))}
  end

  def handle_async(:mail_send_probe, {:exit, reason}, socket) do
    {:noreply,
     socket
     |> assign(:mail_send_running?, false)
     |> put_flash(:error, "Mail send probe crashed: #{inspect(reason)}")}
  end

  def handle_async(:widget_degradation_probe, {:ok, result}, socket) do
    {:noreply,
     socket
     |> assign(:widget_degradation_running?, false)
     |> assign(:widget_degradation, Map.put(result, :checked_at, DateTime.utc_now()))}
  end

  def handle_async(:widget_degradation_probe, {:exit, reason}, socket) do
    {:noreply,
     socket
     |> assign(:widget_degradation_running?, false)
     |> put_flash(:error, "Widget degradation probe crashed: #{inspect(reason)}")}
  end

  def handle_async(:telemetry_check, {:ok, {environment, result}}, socket) do
    socket =
      socket
      |> assign(:telemetry_check_running?, false)
      |> assign(:telemetry_check_environment, nil)

    socket =
      if socket.assigns.environment == environment,
        do: assign(socket, :telemetry_check, result),
        else: socket

    {:noreply, socket}
  end

  def handle_async(:telemetry_check, {:exit, reason}, socket) do
    socket =
      if socket.assigns.environment == socket.assigns[:telemetry_check_environment],
        do: put_flash(socket, :error, "Telemetry check crashed: #{inspect(reason)}"),
        else: socket

    {:noreply,
     socket
     |> assign(:telemetry_check_running?, false)
     |> assign(:telemetry_check_environment, nil)}
  end

  # `refresh/1`, not a full `handle_params` recompute: a broadcast changes the
  # plan and environment state, never the URL-driven assigns.
  @impl true
  def handle_info({:provisioning, :step, row}, socket) do
    socket = refresh(socket)

    # Only the mail steps refresh the cached mail state, so other broadcasts skip
    # the Resend round-trip.
    {:noreply, if(row.key in [:email, :inbound], do: refresh_mail(socket), else: socket)}
  end

  def handle_info({:provisioning, :finished, _result}, socket), do: {:noreply, refresh(socket)}
  def handle_info(_message, socket), do: {:noreply, socket}

  defp storage_probe_state(%{storage_probe_running?: true}), do: "running"
  defp storage_probe_state(%{storage_probe_result: nil}), do: "unchecked"
  defp storage_probe_state(_assigns), do: "checked"

  defp storage_probe_field(nil, _key), do: nil
  defp storage_probe_field(result, key), do: Map.get(result, key)

  # Runs inside `start_async` so the page does not block on the provider.
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
        %{
          key: key,
          environment: environment,
          status: "200",
          matches: false,
          reason: "bytes differ"
        }

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

  defp restore_probe_state(%{restore_probe_running?: true}), do: "running"
  defp restore_probe_state(%{restore_probe_result: nil}), do: "unchecked"
  defp restore_probe_state(_assigns), do: "checked"

  defp restore_probe_field(nil, _key), do: nil
  defp restore_probe_field(result, key), do: Map.get(result, key)

  defp run_restore_probe(scope, environment, options) do
    dumps = list_backups(scope, options)

    case {Storage.credentials(scope, options), dumps} do
      {:none, _} ->
        %{state: "failed", rows: 0, reason: Storage.credentials_instructions()}

      {_, []} ->
        %{state: "failed", rows: 0, reason: "there is no dump in the bucket to restore"}

      {{:ok, credentials}, [newest | _]} ->
        restore_opts =
          step_opts()
          |> Keyword.put(:bucket, newest.bucket)
          |> Keyword.put(:credentials, credentials)

        case Backups.restore_proof(environment, newest.key, restore_opts) do
          {:ok, proof} ->
            %{state: "succeeded", rows: proof.rows, target: proof.target, reason: nil}

          {:error, reason} ->
            %{state: "failed", rows: 0, reason: reason}
        end
    end
  end

  defp list_backups(scope, options) do
    case Storage.credentials(scope, options) do
      :none ->
        []

      {:ok, credentials} ->
        for environment <- Provisioning.environment_names(scope),
            bucket = Storage.bucket_name(scope.active_project, environment),
            {:ok, dumps} <- [Storage.list_dumps(bucket, credentials, options)],
            dump <- dumps do
          Map.merge(dump, %{environment: environment, bucket: bucket, age_days: age_days(dump)})
        end
    end
  end

  defp age_days(%{taken_at: taken_at}) when is_binary(taken_at) do
    case DateTime.from_iso8601(taken_at) do
      {:ok, at, _} -> DateTime.diff(now(), at, :day)
      _ -> 0
    end
  end

  defp age_days(_dump), do: 0

  defp now, do: Keyword.get(step_opts(), :now, &DateTime.utc_now/0).()

  defp content_publish_state(%{content_publish_running?: true}), do: "running"
  defp content_publish_state(%{content_publish_result: nil}), do: "unchecked"
  defp content_publish_state(_assigns), do: "checked"

  defp content_publish_field(nil, _key), do: nil
  defp content_publish_field(result, key), do: Map.get(result, key)

  defp run_content_publish(scope, opts) do
    case ContentPublishing.run(scope, opts) do
      %{state: :rendered} = ran ->
        %{
          state: "published",
          manual_steps_remaining: "0",
          objects_uploaded: true,
          error: nil,
          summary: "published and rendered at #{ran.render[:path]}"
        }

      %{state: state, published: published, reason: reason} ->
        %{
          state: to_string(state),
          manual_steps_remaining: "1",
          objects_uploaded: is_map(published) and published[:objects] not in [nil, []],
          error: reason,
          summary: "publish did not finish"
        }
    end
  end

  defp publish_opts(scope) do
    [
      path: "/",
      expect: "<html",
      site_url: site_url(scope.active_project.domain),
      runtime: operation_environment(scope)
    ]
  end

  defp site_url(name) do
    :code_my_spec
    |> Application.get_env(:provisioning_step_opts, [])
    |> Keyword.get(:site_url)
    |> site_url_or_domain(name)
  end

  defp site_url_or_domain(configured, _name) when is_binary(configured) and configured != "",
    do: configured

  defp site_url_or_domain(_configured, name) when is_binary(name) and name != "",
    do: "https://#{name}"

  defp site_url_or_domain(_configured, _name), do: nil

  defp mail_inbound_state(%{mail_inbound_running?: true}), do: "running"
  defp mail_inbound_state(%{mail_inbound_result: nil}), do: "unchecked"
  defp mail_inbound_state(_assigns), do: "checked"

  # A search/purchase flow, not a check: "running" or "idle".
  defp domain_search_state(%{domain_check_running?: true}), do: "running"
  defp domain_search_state(%{domain_purchase_running?: true}), do: "running"
  defp domain_search_state(_assigns), do: "idle"

  defp mail_send_state(%{mail_send_running?: true}), do: "running"
  defp mail_send_state(%{mail_send_result: nil}), do: "unchecked"
  defp mail_send_state(_assigns), do: "checked"

  defp mail_send_field(nil, _key), do: nil
  defp mail_send_field(result, key), do: Map.get(result, key)

  defp widget_degradation_state(%{widget_degradation_running?: true}), do: "running"
  defp widget_degradation_state(%{widget_degradation: nil}), do: "unchecked"
  defp widget_degradation_state(_assigns), do: "checked"

  defp widget_degradation_field(nil, _key), do: nil
  defp widget_degradation_field(result, key), do: Map.get(result, key)

  defp telemetry_check_state(%{telemetry_check_running?: true}), do: "running"
  defp telemetry_check_state(%{telemetry_check: nil}), do: "unchecked"
  defp telemetry_check_state(_assigns), do: "checked"

  defp telemetry_check_field(nil, _key), do: nil
  defp telemetry_check_field(result, key), do: Map.get(result, key)

  defp mail_inbound_field(nil, _key), do: nil
  defp mail_inbound_field(result, key), do: Map.get(result, key)

  defp run_mail_inbound_probe(scope, to) do
    now = DateTime.to_iso8601(DateTime.utc_now())

    case Provisioning.probe_inbound(scope, to) do
      {:ok, message} ->
        %{
          state: "delivered",
          destination: to,
          message_id: message["id"],
          completed_at: message["created_at"] || now,
          delivered_to: "app",
          body_available: message_body?(message),
          manual_forward: false,
          summary: "delivered to #{to}"
        }

      {:error, reason} ->
        %{
          state: "undelivered",
          destination: to,
          message_id: nil,
          completed_at: now,
          delivered_to: nil,
          body_available: false,
          manual_forward: nil,
          summary: "not delivered to #{to}: #{String.slice(to_string(reason), 0, 200)}"
        }
    end
  end

  defp message_body?(message) do
    Enum.any?(["text", "html"], fn key ->
      case message[key] do
        value when is_binary(value) and value != "" -> true
        _ -> false
      end
    end)
  end

  defp default_inbound_address(scope, domain) do
    local = scope.user.email |> to_string() |> String.split("@") |> List.first()
    "#{local}@#{domain}"
  end

  # Adoption first: a domain already owned needs no purchase offer.
  defp run_domain_check(scope, name) do
    case Cloudflare.owned?(scope, name) do
      {:ok, true} ->
        {:adopt, name}

      _ ->
        case Cloudflare.check_availability(scope, name) do
          {:ok, check} -> {:checked, name, check}
          {:error, reason} -> {:check_failed, name, reason}
        end
    end
  end

  defp run_domain_purchase(scope, name) do
    case Cloudflare.ensure_domain(scope, name, confirmed: true) do
      {:ok, :adopted} -> {:adopt, name}
      {:ok, _body} -> {:register, name}
      {:paused, message} -> {:paused, message}
      {:error, reason} -> {:purchase_failed, reason}
    end
  end

  defp adopt_domain(socket, name), do: register_domain_on_project(socket, name, true)

  defp register_domain_on_project(socket, name, adopted?) do
    scope = socket.assigns.current_scope

    case Projects.update_project(scope, scope.active_project, %{domain: name}) do
      {:ok, project} ->
        scope = %{scope | active_project: project}

        if adopted?, do: Provisioning.adopt_domain_step(scope, name)

        socket
        |> assign(:current_scope, scope)
        |> refresh()

      {:error, _} ->
        assign(socket, :domain_error, "Could not record #{name} on the project.")
    end
  end

  defp availability_label(%{availability: :available}), do: "available"
  defp availability_label(%{availability: :taken}), do: "taken"
  defp availability_label(_check), do: "check the dashboard"

  defp registered_domain(%{active_project: %{domain: d}} = scope)
       when is_binary(d) and d != "" do
    adopted? =
      case Provisioning.get_step(scope, :domain) do
        %{resources: resources} ->
          Enum.any?(resources, &(&1.kind == "domain" and &1.origin == "adopted"))

        _ ->
          false
      end

    %{name: d, adopted: adopted?}
  end

  defp registered_domain(_scope), do: nil

  defp describe_domain_error({_tag, status, _body}), do: "Cloudflare refused (#{status})."
  defp describe_domain_error(:confirmation_required), do: "Registration needs an explicit yes."
  defp describe_domain_error(reason) when is_binary(reason), do: reason
  defp describe_domain_error(reason), do: inspect(reason)

  defp run_mail_send_probe(scope, to, environment) do
    case Resend.send_probe(scope, to, environment: environment) do
      {:ok, sent} ->
        state = mail_state(scope, environment, list_domains(scope))

        %{
          from: sent.from,
          accepted: true,
          provider_id: sent.id,
          completed_at: DateTime.to_iso8601(DateTime.utc_now()),
          dkim: state && state.dkim,
          domain: state && state.domain,
          reason: nil
        }

      {:error, reason} ->
        %{
          from: Resend.probe_from(scope, environment),
          accepted: false,
          provider_id: nil,
          completed_at: DateTime.to_iso8601(DateTime.utc_now()),
          dkim: nil,
          domain: nil,
          reason: inspect(reason) |> String.slice(0, 200)
        }
    end
  end

  # `assign`, not `assign_new`: that is what "re-check" means.
  defp refresh_mail(socket) do
    scope = socket.assigns.current_scope
    domains = list_domains(scope)

    socket
    |> assign(:mail, mail_state(scope, "prod", domains))
    |> assign(:mail_domains, mail_domains(scope, domains))
  end

  defp list_domains(%{active_project: %{domain: d}} = scope) when is_binary(d) and d != "" do
    case Resend.list_domains(scope) do
      {:ok, domains} when is_list(domains) -> domains
      _ -> []
    end
  end

  defp list_domains(_scope), do: []

  defp mail_domains(scope, domains) do
    scope
    |> Provisioning.environment_names()
    |> Enum.map(&mail_state(scope, &1, domains))
    |> Enum.reject(&is_nil/1)
  end

  defp mail_state(scope, environment, domains) do
    with %{domain: base} when is_binary(base) and base != "" <- scope.active_project,
         sending <- Resend.sending_domain(base, environment),
         found when is_map(found) <- Enum.find(domains, &(&1["name"] == sending)),
         {:ok, domain} <- fetch_full_domain(scope, found) do
      records = Resend.records(domain)

      %{
        domain: domain["name"],
        environment: environment,
        status: domain["status"],
        provider_id: domain["id"],
        attempts: verification_attempts(scope),
        verified_at: domain["created_at"],
        dkim: dkim_state(records),
        manual_step_required: domain["status"] not in ["verified", "pending"],
        records:
          Enum.map(records, &mail_record(&1, domain["name"])) ++
            apex_mx_records(domain["name"]),
        missing_records:
          records |> Enum.filter(&(&1["status"] == "not_started")) |> Enum.map(& &1["name"])
      }
    else
      _ -> nil
    end
  end

  defp fetch_full_domain(scope, %{"id" => id} = found) do
    case Resend.get_domain(scope, id) do
      {:ok, %{"data" => domain}} -> {:ok, domain}
      {:ok, domain} when is_map(domain) -> {:ok, domain}
      _ -> {:ok, found}
    end
  end

  defp verification_attempts(scope) do
    scope
    |> Provisioning.plan([:email])
    |> Enum.find(&(&1.key == :email))
    |> case do
      %{resources: resources} ->
        resources
        |> Enum.find(&(&1.kind == "verification"))
        |> case do
          %{location: location} -> location |> to_string() |> String.replace(~r/\D/, "")
          _ -> "0"
        end

      _ ->
        "0"
    end
  end

  defp mail_record(record, base) do
    verified = record["status"] in ["verified", "success"]
    name = apex_or_qualified(record["name"], base)

    %{
      type: record["type"],
      name: name,
      verified: verified,
      resolved: resolves?(name, base, record["type"]),
      content: record["value"]
    }
  end

  defp resolves?(name, base, type) do
    query = if name == "@", do: base, else: name

    record_type =
      case String.upcase(to_string(type)) do
        "MX" -> :mx
        "TXT" -> :txt
        "CNAME" -> :cname
        _ -> :a
      end

    case Application.get_env(:code_my_spec, :dns_resolver) do
      resolver when is_function(resolver, 2) -> resolver.(query, record_type)
      _ -> Dns.lookup_authoritative(query, record_type) != []
    end
  end

  defp apex_mx_records(base) do
    if resolves?("@", base, "MX") do
      [%{type: "MX", name: "@", verified: true, resolved: true, content: base}]
    else
      []
    end
  end

  defp apex_or_qualified(name, _base) when name in [nil, "", "@"], do: "@"
  defp apex_or_qualified(name, base), do: qualify_record(name, base)

  defp qualify_record(name, base) when name in [nil, "", "@"], do: base

  defp qualify_record(name, base) do
    zone = base |> String.split(".") |> Enum.take(-2) |> Enum.join(".")
    if String.ends_with?(name, zone), do: name, else: "#{name}.#{zone}"
  end

  defp dkim_state(records) do
    case Enum.find(records, &(String.upcase(to_string(&1["record"] || "")) =~ "DKIM")) do
      nil -> "unknown"
      %{"status" => status} when status in ["verified", "success"] -> "pass"
      _ -> "fail"
    end
  end

  defp widget_degradation({:ok, probe}) do
    %{
      page_status: to_string(probe_field(probe, :page_status)),
      page_usable: probe_field(probe, :page_usable),
      widget_state: probe_field(probe, :widget_state),
      summary: "the page served, and claimed no widget connection"
    }
  end

  defp widget_degradation({:error, probe}) do
    %{
      page_status: to_string(probe_field(probe, :page_status)),
      page_usable: false,
      widget_state: probe_field(probe, :widget_state) || "unknown",
      summary: "the page did not serve"
    }
  end

  defp widget_degradation(_no_site) do
    %{
      page_status: nil,
      page_usable: false,
      widget_state: "unknown",
      summary: "no domain set on the project — nothing to probe"
    }
  end

  defp probe_field(probe, key), do: Map.get(probe, key) || Map.get(probe, Atom.to_string(key))
end
