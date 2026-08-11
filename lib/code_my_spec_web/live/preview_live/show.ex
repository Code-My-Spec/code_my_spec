defmodule CodeMySpecWeb.PreviewLive.Show do
  @moduledoc """
  Hosts the preview pane at `/build/preview`.

  A convenience host rather than the pane's identity. The same component is
  meant to sit on a project page Sam returns to later, so nothing here may
  become something the pane depends on.

  Owns the viewport control, which is what keeps the pane a pure function of
  `src` and state — see `CodeMySpecWeb.PreviewComponents`.

  The state is asked for, never inferred from whether a request succeeded: a
  booting container and a crashed one both fail to answer, and telling them
  apart is the distinction the pane renders.
  """

  use CodeMySpecWeb, :live_view

  import CodeMySpecWeb.PreviewComponents

  alias CodeMySpec.Workspaces

  @viewports ~w(full tablet phone)

  @impl true
  def mount(_params, _session, socket) do
    workspace = Workspaces.get_workspace(socket.assigns.current_scope)

    if workspace, do: Workspaces.subscribe_workspace(workspace.project_id)

    {:ok,
     socket
     |> assign(page_title: "Your app")
     |> assign(viewport: "full")
     |> assign_workspace(workspace)}
  end

  @impl true
  def handle_event("viewport", %{"size" => size}, socket) when size in @viewports do
    {:noreply, assign(socket, :viewport, size)}
  end

  # Transitions arrive by broadcast, so the page keeps up without Sam
  # reloading — a visitor who has to reload during a boot sees a spinner and
  # concludes it hung.
  @impl true
  def handle_info({event, workspace}, socket)
      when event in [:booting, :progress, :running, :failed] do
    {:noreply, assign_workspace(socket, workspace)}
  end

  defp assign_workspace(socket, nil) do
    socket
    |> assign(:workspace, nil)
    |> assign(:app_state, :absent)
    |> assign(:src, nil)
  end

  defp assign_workspace(socket, workspace) do
    socket
    |> assign(:workspace, workspace)
    |> assign(:app_state, Workspaces.state(workspace))
    |> assign(:src, Workspaces.url(workspace))
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="mx-auto max-w-5xl p-6">
      <div :if={@app_state != :absent} class="mb-4 flex gap-2" data-test="viewport-controls">
        <button
          :for={size <- viewports()}
          type="button"
          data-test={"viewport-#{size}"}
          phx-click="viewport"
          phx-value-size={size}
          class={["btn btn-sm", @viewport == size && "btn-primary"]}
        >
          {size}
        </button>
      </div>

      <.pane src={@src} state={@app_state} viewport={@viewport} />

      <p :if={@app_state == :absent} data-test="preview-none" class="text-sm opacity-70">
        Nothing has been built yet.
      </p>
    </div>
    """
  end

  defp viewports, do: @viewports
end
