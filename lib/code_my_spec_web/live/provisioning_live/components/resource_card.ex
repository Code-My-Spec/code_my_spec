defmodule CodeMySpecWeb.ProvisioningLive.Components.ResourceCard do
  @moduledoc """
  One row of the "What you now own" panel.

  Factored out of the panel's `<li>` the same way `StatusBadge` was factored
  out of `step_card` — a plain function component, every field already
  resolved by `owned_resources/2` so this is pure presentation. `verified?`
  and `unverified_note` are about the present, not the past: "What you now
  own" claims what exists right now, and `reverify/3` keeps a resource's
  record when its step no longer verifies — deliberately, since teardown
  works from that record — so the record can outlive the resource. A
  resource that no longer verifies is marked, not dropped.
  """

  use CodeMySpecWeb, :html

  attr :owned, :map, required: true

  def resource_card(assigns) do
    ~H"""
    <li
      data-test="provisioned-resource"
      data-kind={@owned.resource.kind}
      data-location={@owned.resource.location}
      data-environment={@owned.environment}
      data-name={@owned.name}
      data-owner={@owned.owner}
      data-verified={to_string(@owned.verified?)}
      class={not @owned.verified? && "opacity-70"}
    >
      {@owned.resource.kind} — {@owned.resource.location}
      <span
        :if={not @owned.verified?}
        data-test="unverified-resource"
        data-step={@owned.step}
        class="badge badge-sm badge-warning ml-2"
      >
        {@owned.unverified_note}
      </span>
    </li>
    """
  end
end
