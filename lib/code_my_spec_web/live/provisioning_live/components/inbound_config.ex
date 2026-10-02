defmodule CodeMySpecWeb.ProvisioningLive.Components.InboundConfig do
  @moduledoc """
  The inbound step's own markup, factored out of `step_card`'s branches.

  Three pieces, in the order a pause resolves: the MX-repoint dialog
  (22b0e27c — `check_competing_mx/3` refuses to replace an MX the domain
  already has, since it might be routing real mail today, so overwriting it
  is a decision Sam makes, not a default); the probe-address form for when
  nothing gave Sam a way to supply the address `default_inbound_probe/3`
  refused to guess (4ed72738 — excludes the MX-conflict pause, which the
  repoint dialog answers instead); and the delivery proof itself — the step
  sends a message to the domain it just configured and waits for Resend to
  report it received, so that delivery is the claim rather than folded into
  "done" (criterion 8033).
  """

  use CodeMySpecWeb, :html

  import CodeMySpecWeb.ProvisioningLive.ResourceFields

  attr :step, :map, required: true
  attr :mx_conflict?, :boolean, required: true

  def inbound_config(assigns) do
    ~H"""
    <div
      :if={@step.state == :paused and @mx_conflict?}
      data-test="inbound-mx-repoint"
      class="mt-3 flex gap-2"
    >
      <.button
        data-test="confirm-inbound-mx-repoint"
        class="btn btn-warning"
        phx-click={show_confirm("confirm-inbound-mx-repoint")}
      >
        Repoint it anyway
      </.button>

      <.confirm_dialog
        id="confirm-inbound-mx-repoint"
        title="Replace the existing MX record?"
        message={@step.paused_instructions}
        confirm_label="Repoint it"
        on_confirm={JS.push("confirm_inbound_mx_repoint")}
      />
    </div>

    <form
      :if={@step.state == :paused and not @mx_conflict?}
      data-test="inbound-probe-address"
      phx-submit="run_step_with_probe_address"
      class="mt-3 flex gap-2"
    >
      <input type="hidden" name="key" value={@step.key} />
      <input
        type="email"
        name="probe_to"
        data-test="inbound-probe-address-input"
        placeholder="an address you already receive at this domain"
        required
        class="input input-bordered input-sm flex-1"
      />
      <.button type="submit" data-test="inbound-probe-address-submit" class="btn btn-primary">
        Use this address
      </.button>
    </form>

    <span
      :for={pr <- Enum.filter(@step.resources, &(&1.kind == "inbound_proof"))}
      data-test="inbound-delivery-proof"
      data-target={pr.location}
      data-state={proof_field(pr.identifier, "state")}
      data-message-id={proof_field(pr.identifier, "message_id")}
      data-completed-at={proof_field(pr.identifier, "proven_at")}
      class="mt-1 block text-xs font-mono opacity-70"
    >
      delivered to {pr.location}: {pr.identifier}
    </span>
    """
  end
end
