defmodule CodeMySpecWeb.ActivityComponents do
  @moduledoc """
  The project's last 7 days at a glance: tokens spent, stories shipped and
  messages sent to agents as three numbers, and the activity-over-time chart in
  a modal.
  """
  use CodeMySpecWeb, :html

  alias CodeMySpecWeb.Format

  @doc "Tokens · shipped · messages, this week."
  attr :summary, :map, required: true
  attr :rest, :global

  def summary_mark(assigns) do
    ~H"""
    <button
      type="button"
      data-test="activity-counts"
      data-tokens={@summary.tokens}
      data-shipped={@summary.shipped}
      data-messages={@summary.messages}
      data-tip={"This week: #{@summary.tokens} tokens · #{@summary.shipped} stories shipped · #{@summary.messages} messages"}
      class="tooltip tooltip-left flex items-center gap-2 font-mono text-xs tabular-nums"
      {@rest}
    >
      <span class="flex items-center gap-0.5 opacity-70">
        <.icon name="hero-bolt" class="size-3" />{Format.compact(@summary.tokens)}
      </span>
      <span class="flex items-center gap-0.5 text-success">
        <.icon name="hero-rocket-launch" class="size-3" />{Format.compact(@summary.shipped)}
      </span>
      <span class="flex items-center gap-0.5 opacity-70">
        <.icon name="hero-chat-bubble-left" class="size-3" />{Format.compact(@summary.messages)}
      </span>
    </button>
    """
  end

  @doc """
  The activity chart over whatever page is open. `option` is the chart's data,
  or `:loading` while it is read. Pushes `on_close`.
  """
  attr :option, :any, required: true
  attr :summary, :map, required: true
  attr :on_close, :string, required: true

  def modal(assigns) do
    ~H"""
    <div
      class="modal modal-open"
      role="dialog"
      aria-modal="true"
      data-test="activity-modal"
      phx-window-keydown={@on_close}
      phx-key="Escape"
    >
      <div class="modal-box w-11/12 max-w-5xl space-y-3">
        <button
          type="button"
          phx-click={@on_close}
          class="btn btn-ghost btn-sm btn-circle absolute right-2 top-2"
          aria-label="Close"
        >
          <.icon name="hero-x-mark" class="size-5" />
        </button>
        <div class="flex flex-wrap items-baseline gap-x-3 gap-y-1 pr-8">
          <h2 class="text-lg font-semibold">Activity this week</h2>
          <span class="text-xs opacity-60">
            {Format.compact(@summary.tokens)} tokens · {@summary.shipped} shipped · {Format.compact(
              @summary.messages
            )} messages
          </span>
        </div>
        <div class="relative" style="height: 340px">
          <div :if={@option == :loading} class="flex h-full items-center justify-center">
            <span class="loading loading-spinner loading-md opacity-60" aria-label="Loading"></span>
          </div>
          <div
            :if={is_map(@option)}
            id={"activity-chart-#{:erlang.phash2(@option)}"}
            data-test="activity-chart"
            phx-hook="EChart"
            phx-update="ignore"
            data-option={Jason.encode!(@option)}
            style="height: 100%"
          >
          </div>
        </div>
      </div>
      <button type="button" class="modal-backdrop" phx-click={@on_close} aria-label="Close"></button>
    </div>
    """
  end
end
