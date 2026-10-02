defmodule CodeMySpecWeb.ProvisioningLive.Components.ServerConfig do
  @moduledoc """
  The server step's own markup, factored out of `step_card`'s branches.

  The firewall's inbound rules, from the deterministic rule set: only the
  web ports and key-only SSH face the internet, and the database port never
  does (criterion 8004). Shown once the server step has recorded a firewall.
  """

  use CodeMySpecWeb, :html

  alias CodeMySpec.Provisioning.Hetzner

  attr :step, :map, required: true

  def server_config(assigns) do
    ~H"""
    <div
      :if={Enum.any?(@step.resources, &(&1.kind == "firewall"))}
      class="mt-2 flex flex-col gap-1"
    >
      <span
        :for={rule <- Hetzner.default_firewall_rules()}
        data-test="firewall-rule"
        data-direction="in"
        data-port={rule.port}
        data-source={hd(rule.source_ips)}
        class="text-xs font-mono opacity-70"
      >
        in {rule.port} from {Enum.join(rule.source_ips, ", ")}
      </span>
      <span data-test="firewall-scope" data-enforced-at="cloud" class="text-xs opacity-50">
        enforced at the Hetzner cloud firewall, not on the box
      </span>
    </div>
    """
  end
end
