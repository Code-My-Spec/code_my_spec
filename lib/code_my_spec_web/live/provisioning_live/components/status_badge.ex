defmodule CodeMySpecWeb.ProvisioningLive.Components.StatusBadge do
  @moduledoc """
  A step's state, plus — for a done step — when it was last checked.

  Factored out of `step_card` the same way `CredentialsForm` was: a plain
  function component, no state or lifecycle of its own, just the two spans
  every step card showed inline. `verified_at` is exactly when a check last
  happened (checks are manual only, John 2026-10-02) — it is never set by a
  step merely finishing, so a done step with no check yet reads "unchecked"
  rather than implying one just happened.
  """

  use CodeMySpecWeb, :html

  attr :state, :atom, required: true
  attr :step_key, :atom, required: true
  attr :verified_at, :any, default: nil

  def status_badge(assigns) do
    ~H"""
    <span class="badge">{@state}</span>
    <span
      :if={@state == :done}
      data-test="checked-note"
      data-step={@step_key}
      class="text-xs opacity-60"
    >
      {checked_note(@verified_at)}
    </span>
    """
  end

  defp checked_note(%DateTime{} = at), do: "checked #{ago(at)}"
  defp checked_note(_verified_at), do: "unchecked"

  defp ago(%DateTime{} = at) do
    case DateTime.diff(DateTime.utc_now(), at, :second) do
      s when s < 90 -> "#{s}s ago"
      s when s < 5400 -> "#{div(s, 60)}m ago"
      s when s < 86_400 -> "#{div(s, 3600)}h ago"
      s -> "#{div(s, 86_400)}d ago"
    end
  end
end
