defmodule CodeMySpecWeb.TaskComponents do
  @moduledoc """
  An agent's task, as the agent was handed it: the directive
  `get_next_requirement` gives for its requirement, the same text the
  next-task page shows.
  """
  use CodeMySpecWeb, :html

  import CodeMySpecWeb.Markdown, only: [md_html: 1]

  @doc """
  A task over whatever page is open. `directive` is `:loading` while it is
  read, nil when the graph no longer holds the requirement. Pushes `on_close`
  to close.
  """
  attr :title, :string, required: true
  attr :directive, :any, required: true
  attr :project_id, :string, required: true
  attr :on_close, :string, required: true

  def modal(assigns) do
    ~H"""
    <div
      class="modal modal-open"
      role="dialog"
      aria-modal="true"
      data-test="task-modal"
      phx-window-keydown={@on_close}
      phx-key="Escape"
    >
      <div class="modal-box w-11/12 max-w-3xl space-y-3">
        <button
          type="button"
          phx-click={@on_close}
          class="btn btn-ghost btn-sm btn-circle absolute right-2 top-2"
          aria-label="Close"
        >
          <.icon name="hero-x-mark" class="size-5" />
        </button>
        <h2 class="pr-8 text-lg font-semibold">{@title}</h2>
        <p :if={@directive == :loading} class="text-sm opacity-60">Loading…</p>
        <p :if={is_nil(@directive)} data-test="task-modal-gone" class="text-sm opacity-60">
          The graph no longer holds this requirement — it may have been satisfied.
        </p>
        <div
          :if={is_binary(@directive)}
          data-test="task-modal-directive"
          class="prose prose-sm max-w-none max-h-[65vh] overflow-y-auto rounded-box border border-base-300 bg-base-200 p-4"
        >
          {md_html(@directive)}
        </div>
        <div class="flex justify-end">
          <.link
            navigate={~p"/app/projects/#{@project_id}/next-task"}
            class="btn btn-sm btn-ghost"
          >
            Next task <.icon name="hero-arrow-top-right-on-square" class="size-4" />
          </.link>
        </div>
      </div>
      <button type="button" class="modal-backdrop" phx-click={@on_close} aria-label="Close"></button>
    </div>
    """
  end
end
