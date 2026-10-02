defmodule CodeMySpecWeb.ConsoleLive.Components.DiagnosticsPanel do
  @moduledoc """
  One manual check inside a resource's Checks tab — a title, "checked …
  ago"/"unchecked", and the probe's own form and result as its inner block.

  Deliberately thin: each probe's inputs and result shape are different
  (storage writes a key/value, a domain check returns availability and
  price, a restore reports rows), so this only owns the one thing every
  probe shares — when it was last run, read the same way `StatusBadge`
  reads a step's `verified_at`.
  """

  use CodeMySpecWeb, :html

  attr :title, :string, required: true
  attr :checked_at, :any, default: nil
  slot :inner_block, required: true

  def diagnostics_panel(assigns) do
    ~H"""
    <div data-test="diagnostics-panel" class="card bg-base-100">
      <div class="card-body gap-2">
        <div class="flex items-center justify-between">
          <h3 class="card-title text-base">{@title}</h3>
          <span data-test="diagnostics-checked-note" class="text-xs opacity-60">
            {checked_note(@checked_at)}
          </span>
        </div>
        {render_slot(@inner_block)}
      </div>
    </div>
    """
  end

  defp checked_note(nil), do: "unchecked"
  defp checked_note(%DateTime{} = at), do: "checked #{ago(at)}"

  defp ago(%DateTime{} = at) do
    case DateTime.diff(DateTime.utc_now(), at, :second) do
      s when s < 90 -> "#{s}s ago"
      s when s < 5400 -> "#{div(s, 60)}m ago"
      s when s < 86_400 -> "#{div(s, 3600)}h ago"
      s -> "#{div(s, 86_400)}d ago"
    end
  end
end
