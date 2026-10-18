defmodule CodeMySpecWeb.StoryProgress do
  @moduledoc """
  A story's requirements as a pie: how many are satisfied, readable without
  reading.

  Loads its own count, and reloads when told to — the parent forwards
  `{:graph_updated, _}` as `send_update(StoryProgress, id: id, refresh: true)`,
  since a component cannot subscribe on its own. Graph updates rather than task
  completions: a task finishing changes nothing here until the graph is
  recomputed, and the recompute is what broadcasts.

  The count is a full graph read, so it loads off the LiveView process. Inline,
  each pie would hold the cockpit's join and every graph update for seconds, and
  a join that outlasts the client's timeout reloads the page.
  """

  use CodeMySpecWeb, :live_component

  alias CodeMySpec.Requirements

  @impl true
  def update(assigns, socket) do
    {refresh?, assigns} = Map.pop(assigns, :refresh, false)
    socket = assign(socket, assigns)

    stale? =
      refresh? or not Map.has_key?(socket.assigns, :progress) or
        changed?(socket, :story_id) or changed?(socket, :working_copy_id)

    if stale? do
      args = Map.take(socket.assigns, [:scope, :story_id, :working_copy_id])

      {:ok,
       socket
       |> assign_new(:progress, fn -> {0, 0} end)
       |> start_async(:progress, fn -> progress(args) end)}
    else
      {:ok, socket}
    end
  end

  # A failed load keeps the last count rather than blanking the pie.
  @impl true
  def handle_async(:progress, {:ok, progress}, socket),
    do: {:noreply, assign(socket, :progress, progress)}

  def handle_async(:progress, {:exit, _reason}, socket), do: {:noreply, socket}

  defp progress(%{scope: scope, story_id: story_id, working_copy_id: copy_id}),
    do: Requirements.story_progress(%{scope | active_working_copy_id: copy_id}, story_id)

  @impl true
  def render(assigns) do
    {done, total} = assigns.progress
    assigns = assign(assigns, done: done, total: total)

    ~H"""
    <button
      type="button"
      id={@id}
      phx-click="show_story_graph"
      phx-value-story-id={@story_id}
      phx-value-copy-id={@working_copy_id}
      data-test="story-progress"
      data-done={@done}
      data-total={@total}
      title={"#{@done} of #{@total} requirements satisfied"}
      style={"background: conic-gradient(currentColor #{percent(@done, @total)}%, transparent 0)"}
      class={[
        "inline-block size-3 shrink-0 cursor-pointer rounded-full ring-1",
        if(@total > 0 and @done == @total,
          do: "text-success ring-success/60",
          else: "text-primary ring-base-content/25"
        )
      ]}
      aria-label={"Show the requirements graph: #{@done} of #{@total} satisfied"}
    ></button>
    """
  end

  defp percent(_done, 0), do: 0
  defp percent(done, total), do: round(done / total * 100)
end
