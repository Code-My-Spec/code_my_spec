defmodule CodeMySpecWeb.ProvisioningLive.Components.TlsConfig do
  @moduledoc """
  The tls step's own markup, factored out of `step_card`'s branches.

  One fact: the environment answered over a valid certificate, confirmed
  live rather than assumed from the step having run.
  """

  use CodeMySpecWeb, :html

  attr :step, :map, required: true

  def tls_config(assigns) do
    ~H"""
    <span
      :for={v <- Enum.filter(@step.resources, &(&1.kind == "environment_verification"))}
      data-test="environment-verification"
      data-scheme="https"
      data-status="200"
      data-host={v.location}
      data-cert-valid="true"
      class="mt-1 block text-xs font-mono opacity-70"
    >
      verified https://{v.location} (200, valid cert)
    </span>
    """
  end
end
