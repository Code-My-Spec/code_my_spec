defmodule CodeMySpecWeb.ConsoleLive.Components.ResourceDetail do
  @moduledoc """
  One resource group's Config, Checks and Activity tabs — the plan's
  replacement for `step_card`'s inline everything, now one tab set for
  every step key `ResourceGroups` folds under this resource (DNS and
  domain is :domain, :dns and :tls together, for instance).

  Config reuses the exact per-step components step 5 extracted
  (RepositoryConfig, ServerConfig, DnsConfig, and so on), the run/retry
  button, paused-instructions and escalation — the same markup `step_card`
  showed, once per step in the group, under a tab instead of always-on.
  `:domain_search`, `:mail_panel` and `:backups_panel` are the same Config
  tab's project-level exceptions — the domain search/purchase/confirm tool,
  the outbound mail/DKIM panel, and the backup-bucket health/listing panel
  aren't any single step's own markup, so they render below the step list
  rather than per-step; `ConsoleLive` passes them for `:dns_domain`, `:mail`
  and `:storage_backups` respectively. Checks renders whatever
  `ConsoleLive` passes through the `:checks` slot — one `DiagnosticsPanel`
  per probe that group owns — and falls back to a placeholder for groups
  that don't have one wired up yet (see the moduledoc on `ConsoleLive` for
  which do). Activity renders `activity_entries` as `ConsoleLive` passes
  it — `CodeMySpec.Activity.list_for_resource/2`'s own rows, not derived
  from `@steps` — so this tab shows only entries recorded against this
  resource's own key.
  """

  use CodeMySpecWeb, :html

  alias CodeMySpecWeb.ProvisioningLive.Components.BackupsConfig
  alias CodeMySpecWeb.ProvisioningLive.Components.CallbackCredentialConfig
  alias CodeMySpecWeb.ProvisioningLive.Components.ContentConfig
  alias CodeMySpecWeb.ProvisioningLive.Components.DeployConfig
  alias CodeMySpecWeb.ProvisioningLive.Components.DnsConfig
  alias CodeMySpecWeb.ProvisioningLive.Components.InboundConfig
  alias CodeMySpecWeb.ProvisioningLive.Components.RepositoryConfig
  alias CodeMySpecWeb.ProvisioningLive.Components.ServerConfig
  alias CodeMySpecWeb.ProvisioningLive.Components.StatusBadge
  alias CodeMySpecWeb.ProvisioningLive.Components.TlsConfig
  alias CodeMySpecWeb.ProvisioningLive.Components.WidgetConfig
  alias CodeMySpecWeb.ProvisioningLive.ResourceFields

  attr :group, :map, default: nil
  attr :steps, :list, required: true
  attr :environments, :list, required: true
  attr :age_key_environments, :list, required: true
  attr :runs_in_flight?, :boolean, required: true
  attr :tab, :string, required: true
  attr :project_id, :any, required: true
  attr :environment, :string, required: true
  attr :activity_entries, :list, required: true
  slot :checks
  slot :domain_search
  slot :mail_panel
  slot :backups_panel

  def resource_detail(%{group: nil} = assigns) do
    ~H"""
    <p data-test="resource-not-found" class="opacity-70">
      No such resource.
    </p>
    """
  end

  def resource_detail(assigns) do
    ~H"""
    <section data-test="resource-detail" data-resource={@group.key} class="flex flex-col gap-4">
      <h2 class="text-xl font-semibold">{@group.label}</h2>

      <div role="tablist" class="tabs tabs-boxed w-fit">
        <.link
          patch={tab_path(@project_id, @group.key, @environment, "config")}
          data-test="resource-tab-config"
          role="tab"
          class={["tab", @tab == "config" && "tab-active"]}
        >
          Config
        </.link>
        <.link
          patch={tab_path(@project_id, @group.key, @environment, "checks")}
          data-test="resource-tab-checks"
          role="tab"
          class={["tab", @tab == "checks" && "tab-active"]}
        >
          Checks
        </.link>
        <.link
          patch={tab_path(@project_id, @group.key, @environment, "activity")}
          data-test="resource-tab-activity"
          role="tab"
          class={["tab", @tab == "activity" && "tab-active"]}
        >
          Activity
        </.link>
      </div>

      <div
        :if={@tab == "config"}
        data-test="resource-tab-panel"
        data-panel="config"
        class="flex flex-col gap-4"
      >
        <p :if={@steps == []} class="opacity-70 text-sm" data-test="resource-no-steps">
          Nothing in this environment yet.
        </p>

        <div
          :for={step <- @steps}
          data-test="resource-step"
          data-step={step.key}
          data-state={step.state}
          data-environment={step.environment}
          data-completed-at={step_completed_at(step)}
          data-started-at={step_started_at(step)}
          data-verified-at={step_verified_at(step)}
          class="card bg-base-100"
        >
          <div class="card-body p-4 gap-2">
            <div class="flex items-center justify-between">
              <h3 class="font-semibold">{step.label}</h3>
              <div class="flex items-center gap-2">
                <StatusBadge.status_badge
                  state={step.state}
                  step_key={step.key}
                  verified_at={step.verified_at}
                />
                <.button
                  :if={step.key != :deploy}
                  data-test={if step.state == :errored, do: "retry-step", else: "run-step"}
                  phx-click="run_step"
                  phx-value-key={step.key}
                  phx-value-environment={step.environment}
                  disabled={@runs_in_flight?}
                >
                  {if step.state == :errored, do: "Retry", else: "Run"}
                </.button>
              </div>
            </div>

            <p
              :if={step.state == :paused && step.paused_instructions}
              data-test="paused-instructions"
              data-step={step.key}
              class="alert alert-warning"
            >
              {step.paused_instructions}
            </p>

            <div
              :if={step.state == :errored}
              data-test="escalation"
              data-step={step.key}
              class="alert alert-error flex-col items-start"
            >
              <p>{step.attempted}</p>
              <p class="font-mono text-xs">{step.provider_error}</p>
            </div>

            <RepositoryConfig.repository_config :if={step.key == :repository} step={step} />
            <ServerConfig.server_config :if={step.key == :server} step={step} />
            <DnsConfig.dns_config :if={step.key == :dns} step={step} environments={@environments} />
            <TlsConfig.tls_config :if={step.key == :tls} step={step} />
            <DeployConfig.deploy_config
              :if={step.key == :deploy}
              step={step}
              age_key_environments={@age_key_environments}
              runs_in_flight?={@runs_in_flight?}
            />
            <InboundConfig.inbound_config
              :if={step.key == :inbound}
              step={step}
              mx_conflict?={inbound_mx_conflict?(step)}
            />
            <CallbackCredentialConfig.callback_credential_config
              :if={step.key == :callback_credential}
              step={step}
            />
            <ContentConfig.content_config :if={step.key == :content} step={step} />
            <WidgetConfig.widget_config :if={step.key == :widget} step={step} />
            <BackupsConfig.backups_config :if={step.key == :backups} step={step} />

            <div :if={step.resources != []} class="mt-1 flex flex-col gap-1">
              <span
                :for={resource <- step.resources}
                data-test="provisioned-resource"
                data-kind={resource.kind}
                data-location={resource.location}
                data-identifier={resource.identifier}
                data-environment={ResourceFields.resource_environment(resource, @environments)}
                data-name={ResourceFields.resource_name(resource)}
                data-owner={ResourceFields.resource_owner(resource)}
                data-disposition={ResourceFields.resource_disposition(resource)}
                data-historical={to_string(Map.get(resource, :observed_in_latest_run, true) == false)}
                data-verified={
                  to_string(step.state == :done && Map.get(resource, :observed_in_latest_run, true))
                }
                class={[
                  "badge badge-outline",
                  (step.state != :done || Map.get(resource, :observed_in_latest_run, true) == false) &&
                    "badge-warning opacity-70"
                ]}
              >
                {resource.kind} — {resource.location}
                <span
                  :if={Map.get(resource, :observed_in_latest_run, true) == false}
                  data-test="historical-resource"
                  class="ml-1"
                >
                  (earlier record; not confirmed by the latest run)
                </span>
                <span
                  :if={step.state != :done}
                  data-test="unverified-resource"
                  data-step={step.key}
                  class="ml-1"
                >
                  ({unverified_note(step)})
                </span>
              </span>
            </div>
          </div>
        </div>

        {render_slot(@domain_search)}
        {render_slot(@mail_panel)}
        {render_slot(@backups_panel)}
      </div>

      <div
        :if={@tab == "checks"}
        data-test="resource-tab-panel"
        data-panel="checks"
        class="flex flex-col gap-4"
      >
        <p :if={@checks == []} class="opacity-70 text-sm" data-test="checks-placeholder">
          Manual checks move here in a follow-up — the remaining probes still
          run from the old setup page for now.
        </p>
        {render_slot(@checks)}
      </div>

      <div
        :if={@tab == "activity"}
        data-test="resource-tab-panel"
        data-panel="activity"
        class="flex flex-col gap-1"
      >
        <p :if={@activity_entries == []} class="opacity-70 text-sm">Nothing yet.</p>
        <p
          :for={entry <- @activity_entries}
          data-test="resource-activity-entry"
          data-kind={entry.kind}
          data-environment={entry.environment}
          data-actor={entry.actor}
          data-at={DateTime.to_iso8601(entry.inserted_at)}
        >
          {entry.summary} — {entry.actor}
        </p>
      </div>
    </section>
    """
  end

  defp tab_path(project_id, key, environment, tab),
    do: ~p"/app/projects/#{project_id}/console/resources/#{key}?env=#{environment}&tab=#{tab}"

  # Same as ProvisioningLive.inbound_mx_conflict?/1 — duplicated rather than
  # imported since it's a private helper there, and small enough that
  # duplicating it costs less than exposing it.
  defp inbound_mx_conflict?(%{paused_instructions: instructions}) when is_binary(instructions),
    do: instructions =~ "Confirm to publish anyway"

  defp inbound_mx_conflict?(_step), do: false

  # Same as ProvisioningLive.unverified_note/1 — duplicated for the same
  # reason inbound_mx_conflict?/1 above is.
  defp unverified_note(%{verified_at: %DateTime{} = at}),
    do: "not found #{Calendar.strftime(at, "%b %-d %H:%M")}"

  defp unverified_note(_step), do: "unverified"

  # Same as ProvisioningLive.step_completed_at/started_at/verified_at — same
  # reason the two helpers above are duplicated.
  defp step_completed_at(%{state: :done, completed_at: %DateTime{} = at}),
    do: DateTime.to_iso8601(at)

  defp step_completed_at(_step), do: nil

  defp step_started_at(%{started_at: %DateTime{} = at}), do: DateTime.to_iso8601(at)
  defp step_started_at(_step), do: nil

  defp step_verified_at(%{verified_at: %DateTime{} = at}), do: DateTime.to_iso8601(at)
  defp step_verified_at(_step), do: nil
end
