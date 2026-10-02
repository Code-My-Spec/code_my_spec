defmodule CodeMySpecWeb.ConsoleLive.Components.ResourceDetail do
  @moduledoc """
  One resource's Config, Checks and Activity tabs — the plan's replacement
  for `step_card`'s inline everything.

  Config reuses the exact per-step components step 5 extracted
  (RepositoryConfig, ServerConfig, DnsConfig, and so on), the run/retry
  button, paused-instructions and escalation — the same markup `step_card`
  showed, just under a tab instead of always-on. Checks is a placeholder:
  the five probes (storage, domain, content, restore, inbound) still run
  from the old `/provisioning` page, not yet moved here or converted to
  async — see the moduledoc on `ConsoleLive`. Activity reads the step's own
  timestamps, the same stand-in `ConsoleLive`'s Overview uses, not a
  persisted event log.
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

  attr :step, :map, default: nil
  attr :environments, :list, required: true
  attr :age_key_environments, :list, required: true
  attr :runs_in_flight?, :boolean, required: true
  attr :tab, :string, required: true
  attr :project_id, :any, required: true
  attr :environment, :string, required: true

  def resource_detail(%{step: nil} = assigns) do
    ~H"""
    <p data-test="resource-not-found" class="opacity-70">
      No such resource for this environment.
    </p>
    """
  end

  def resource_detail(assigns) do
    ~H"""
    <section data-test="resource-detail" data-step={@step.key} class="flex flex-col gap-4">
      <div class="flex items-center justify-between">
        <div>
          <h2 class="text-xl font-semibold">{@step.label}</h2>
          <p class="text-sm opacity-70">{@step.why}</p>
        </div>
        <StatusBadge.status_badge
          state={@step.state}
          step_key={@step.key}
          verified_at={@step.verified_at}
        />
      </div>

      <div role="tablist" class="tabs tabs-boxed w-fit">
        <.link
          patch={tab_path(@project_id, @step.key, @environment, "config")}
          data-test="resource-tab-config"
          role="tab"
          class={["tab", @tab == "config" && "tab-active"]}
        >
          Config
        </.link>
        <.link
          patch={tab_path(@project_id, @step.key, @environment, "checks")}
          data-test="resource-tab-checks"
          role="tab"
          class={["tab", @tab == "checks" && "tab-active"]}
        >
          Checks
        </.link>
        <.link
          patch={tab_path(@project_id, @step.key, @environment, "activity")}
          data-test="resource-tab-activity"
          role="tab"
          class={["tab", @tab == "activity" && "tab-active"]}
        >
          Activity
        </.link>
      </div>

      <div :if={@tab == "config"} data-test="resource-tab-panel" data-panel="config">
        <.button
          :if={@step.key != :deploy}
          data-test={if @step.state == :errored, do: "retry-step", else: "run-step"}
          phx-click="run_step"
          phx-value-key={@step.key}
          phx-value-environment={@step.environment}
          disabled={@runs_in_flight?}
        >
          {if @step.state == :errored, do: "Retry", else: "Run"}
        </.button>

        <p
          :if={@step.state == :paused && @step.paused_instructions}
          data-test="paused-instructions"
          data-step={@step.key}
          class="alert alert-warning mt-3"
        >
          {@step.paused_instructions}
        </p>

        <div
          :if={@step.state == :errored}
          data-test="escalation"
          data-step={@step.key}
          class="alert alert-error mt-3 flex-col items-start"
        >
          <p>{@step.attempted}</p>
          <p class="font-mono text-xs">{@step.provider_error}</p>
        </div>

        <RepositoryConfig.repository_config :if={@step.key == :repository} step={@step} />
        <ServerConfig.server_config :if={@step.key == :server} step={@step} />
        <DnsConfig.dns_config :if={@step.key == :dns} step={@step} environments={@environments} />
        <TlsConfig.tls_config :if={@step.key == :tls} step={@step} />
        <DeployConfig.deploy_config
          :if={@step.key == :deploy}
          step={@step}
          age_key_environments={@age_key_environments}
          runs_in_flight?={@runs_in_flight?}
        />
        <InboundConfig.inbound_config
          :if={@step.key == :inbound}
          step={@step}
          mx_conflict?={inbound_mx_conflict?(@step)}
        />
        <CallbackCredentialConfig.callback_credential_config
          :if={@step.key == :callback_credential}
          step={@step}
        />
        <ContentConfig.content_config :if={@step.key == :content} step={@step} />
        <WidgetConfig.widget_config :if={@step.key == :widget} step={@step} />
        <BackupsConfig.backups_config :if={@step.key == :backups} step={@step} />
      </div>

      <div :if={@tab == "checks"} data-test="resource-tab-panel" data-panel="checks">
        <p class="opacity-70 text-sm" data-test="checks-placeholder">
          Manual checks move here in a follow-up — the five probes still run
          from the old setup page for now.
        </p>
      </div>

      <div :if={@tab == "activity"} data-test="resource-tab-panel" data-panel="activity">
        <p
          :if={is_nil(@step.completed_at) and is_nil(@step.verified_at)}
          class="opacity-70 text-sm"
        >
          Nothing yet.
        </p>
        <p :if={@step.completed_at} data-test="activity-completed">
          completed {@step.completed_at}
        </p>
        <p :if={@step.verified_at} data-test="activity-verified">
          checked {@step.verified_at}
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
end
