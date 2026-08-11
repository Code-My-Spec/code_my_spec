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

  alias CodeMySpec.Events
  alias CodeMySpec.Workspaces
  alias CodeMySpec.Workspaces.PreviewAddress

  @viewports ~w(full tablet phone)

  @impl true
  def mount(_params, _session, socket) do
    workspace = Workspaces.get_workspace(socket.assigns.current_scope)

    if workspace, do: Workspaces.subscribe_workspace(workspace.project_id)

    {:ok,
     socket
     |> assign(page_title: "Your app")
     |> assign(viewport: "full")
     |> assign(crash: nil)
     |> assign_workspace(workspace)}
  end

  @impl true
  def handle_event("viewport", %{"size" => size}, socket) when size in @viewports do
    {:noreply, assign(socket, :viewport, size)}
  end

  # The app announcing its bridge is alive. Worth knowing on its own: it
  # separates "framed and quiet" from "framed and not reporting", which are the
  # same picture and different problems.
  def handle_event("preview_bridge", %{"type" => "ready"}, socket) do
    {:noreply, assign(socket, :crash, nil)}
  end

  # A crash inside the app. Shown, so Sam is not staring at a frame that went
  # blank with no explanation, and recorded, so it outlives the page — 886 asks
  # for a failed render to become a signal the agent can act on, and a flash
  # message that dies with the socket is not that.
  def handle_event("preview_bridge", %{"type" => "error"} = params, socket) do
    payload = Map.get(params, "payload", %{})

    Events.record(:preview_crash, %{
      project_id: socket.assigns.workspace && socket.assigns.workspace.project_id,
      message: Map.get(payload, "message"),
      source: Map.get(payload, "source"),
      line: Map.get(payload, "line"),
      stack: Map.get(payload, "stack")
    })

    {:noreply,
     assign(socket, :crash, Map.get(payload, "message", "Something failed in your app."))}
  end

  # Anything else the bridge says — it already sends `pong`. The script lives in
  # the generated app rather than here, so it will grow message types on its own
  # schedule, and a pane that dies on an unrecognised one takes the preview down
  # with it. Found exactly that way: the LiveView crashed with a
  # FunctionClauseError on `pong` and the crash banner never rendered, so the
  # symptom was "the receiver does not work" and the cause was one missing
  # clause. An unknown message is not news; a dead LiveView is.
  def handle_event("preview_bridge", _params, socket), do: {:noreply, socket}

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
    # The preview address, not `Workspaces.url/1`. The container's own address
    # refuses to be framed — a generated app sends `frame-ancestors 'self'` —
    # and the refusal is silent: the iframe element looks perfectly healthy
    # while rendering nothing. `PreviewProxy` replaces that header, and it only
    # sees requests that arrive at the preview address.
    |> assign(:src, preview_src(workspace))
  end

  # A preview address is worth pointing at only when there is something behind
  # it; a workspace that is not running has nothing to serve.
  defp preview_src(workspace) do
    case Workspaces.state(workspace) do
      state when state in [:running, :broken] -> PreviewAddress.url(workspace.project_id)
      _ -> nil
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="mx-auto max-w-5xl p-6">
      <script :type={Phoenix.LiveView.ColocatedHook} name=".PreviewBridge">
        export default {
          mounted() {
            // Both checks matter. `source` says it is our bridge speaking;
            // `origin` says it is *this pane's* app speaking. Any page holding
            // a handle on this window can postMessage to it, and without the
            // origin check a hostile frame elsewhere could report crashes into
            // somebody else's preview.
            this.expected = this.el.dataset.previewOrigin;
            this.onMessage = (e) => {
              if (!this.expected || e.origin !== this.expected) return;
              const d = e.data;
              if (!d || d.source !== "cms-preview") return;
              this.pushEvent("preview_bridge", { type: d.type, payload: d.payload || {} });
            };
            window.addEventListener("message", this.onMessage);

            // Announce, rather than wait to be spoken to. This hook mounts when
            // the LiveView connects, which is after the frame has loaded and
            // possibly already crashed — and postMessage has no replay, so a
            // first-paint failure would be lost. The bridge buffers until it
            // hears from us, so saying hello is what releases it.
            //
            // Twice, because either order is possible: the frame may already be
            // loaded when we mount, or still be loading and arrive after.
            this.frame = document.querySelector("[data-test=preview-frame]");
            this.greet = () => {
              if (!this.frame || !this.frame.contentWindow) return;
              this.frame.contentWindow.postMessage(
                { source: "cms-preview-host", type: "ping" },
                this.expected
              );
            };
            this.greet();
            this.frame && this.frame.addEventListener("load", this.greet);
          },
          destroyed() {
            window.removeEventListener("message", this.onMessage);
            this.frame && this.frame.removeEventListener("load", this.greet);
          }
        }
      </script>

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

      <div
        :if={@src}
        id="preview-bridge"
        phx-hook=".PreviewBridge"
        data-preview-origin={@src && URI.parse(@src) |> then(&"#{&1.scheme}://#{&1.authority}")}
      >
      </div>

      <div :if={@crash} data-test="preview-crash" class="alert alert-error mb-4">
        <span class="text-sm">Your app hit an error: {@crash}</span>
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
