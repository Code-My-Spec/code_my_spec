defmodule CodeMySpecWeb.ProvisioningLive.Components.WidgetConfig do
  @moduledoc """
  The widget step's own markup, factored out of `step_card`'s branches.

  Present and openable are asked separately because present-but-not-openable
  is exactly what a broken bundle looks like from the outside (criterion
  8040). A script tag proves nothing on its own — the message proof is one
  that travelled from the deployed site into CodeMySpec, and `origin` is
  what separates it from one posted by hand (criterion 8044).
  """

  use CodeMySpecWeb, :html

  import CodeMySpecWeb.ProvisioningLive.ResourceFields

  attr :step, :map, required: true

  def widget_config(assigns) do
    ~H"""
    <span
      :for={r <- Enum.filter(@step.resources, &(&1.kind == "widget_render"))}
      data-test="widget-render-check"
      data-status={proof_field(r.identifier, "status")}
      data-widget-present={proof_field(r.identifier, "present")}
      data-widget-openable={proof_field(r.identifier, "openable")}
      class="mt-1 block text-xs font-mono opacity-70"
    >
      widget check: {r.identifier}
    </span>

    <span
      :for={pr <- Enum.filter(@step.resources, &(&1.kind == "widget_proof"))}
      data-test="widget-message-proof"
      data-state={proof_field(pr.identifier, "state")}
      data-origin={proof_field(pr.identifier, "origin")}
      data-completed-at={proof_field(pr.identifier, "proven_at")}
      class="mt-1 block text-xs font-mono opacity-70"
    >
      message from {pr.location}: {pr.identifier}
    </span>
    """
  end
end
