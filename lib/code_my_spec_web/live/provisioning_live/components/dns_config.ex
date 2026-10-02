defmodule CodeMySpecWeb.ProvisioningLive.Components.DnsConfig do
  @moduledoc """
  The dns step's own markup, factored out of `step_card`'s branches.

  Three pieces: the apex-repoint dialog for when the apex already points
  somewhere and this run would move it (a live site going dark is less
  reversible than the domain purchase that already demands a second step —
  the money comes back, the downtime does not, so this is behind a dialog
  rather than a bare click); the public-resolver confirmation that a record
  actually resolves, not merely exists; and one row per environment's record,
  so "each environment resolves to its own server" is readable off the page
  rather than inferred.
  """

  use CodeMySpecWeb, :html

  import CodeMySpecWeb.ProvisioningLive.ResourceFields

  attr :step, :map, required: true
  attr :environments, :list, required: true

  def dns_config(assigns) do
    ~H"""
    <div :if={@step.state == :paused} data-test="apex-repoint" class="mt-3 flex gap-2">
      <.button
        data-test="confirm-apex-repoint"
        class="btn btn-warning"
        phx-click={show_confirm("confirm-apex-repoint")}
      >
        Repoint it anyway
      </.button>

      <.confirm_dialog
        id="confirm-apex-repoint"
        title="Repoint the apex?"
        message={@step.paused_instructions}
        confirm_label="Repoint it"
        on_confirm={JS.push("confirm_apex_repoint")}
      />
    </div>

    <span
      :for={v <- Enum.filter(@step.resources, &(&1.kind == "dns_verification"))}
      data-test="dns-verified"
      data-source="resolver"
      data-environment={resource_environment(v, @environments)}
      data-host={v.location}
      class="text-xs opacity-70"
    >
      {v.location} resolves
    </span>

    <span
      :for={record <- Enum.filter(@step.resources, &(&1.kind == "dns_record"))}
      data-test="dns-record"
      data-environment={resource_environment(record, @environments)}
      data-target={resource_target(record)}
      data-name={resource_name(record)}
      data-proxied="false"
      class="text-xs opacity-70"
    >
      {resource_name(record)} → {resource_target(record)}
    </span>
    """
  end
end
