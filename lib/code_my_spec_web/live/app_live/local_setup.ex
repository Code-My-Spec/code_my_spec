defmodule CodeMySpecWeb.AppLive.LocalSetup do
  @moduledoc "Desktop setup controls over the same workflow and status used by Main."
  use CodeMySpecWeb, :live_view
  alias CodeMySpec.Projects.LocalSetup

  @impl true
  def mount(%{"device_id" => device_id}, _, socket) do
    if connected?(socket), do: Process.send_after(self(), :refresh, 1_000)

    {:ok,
     load(
       assign(socket,
         device_id: device_id,
         status: nil,
         error: nil,
         page_title: "Development setup"
       )
     )}
  end

  @impl true
  def handle_event("setup", %{"action" => action}, socket) do
    case run(socket, action) do
      {:ok, status} -> {:noreply, assign(socket, status: status, error: nil)}
      {:error, error} -> {:noreply, assign(socket, error: inspect(error))}
    end
  end

  @impl true
  def handle_info(:refresh, socket) do
    Process.send_after(self(), :refresh, 2_000)
    {:noreply, load(socket)}
  end

  defp load(socket) do
    case run(socket, "status") do
      {:ok, status} -> assign(socket, status: status, error: nil)
      {:error, error} -> assign(socket, error: inspect(error))
    end
  end

  defp run(socket, action) do
    scope = socket.assigns.current_scope

    with %{} <- CodeMySpec.Devices.get_device(scope, socket.assigns.device_id),
         {:ok, status} <- LocalSetup.run(scope, "status"),
         true <- status.device_id == socket.assigns.device_id do
      if action == "status", do: {:ok, status}, else: LocalSetup.run(scope, action)
    else
      _ -> {:error, "Setup is available for this desktop's connected device only."}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} project={@project} projects={@projects}>
      <CodeMySpecWeb.ConsoleLive.Components.Shell.frame project_id={@project.id} active={:dev_boxes}>
        <.link navigate={~p"/app/projects/#{@project.id}/console/dev-boxes"} class="link">Dev boxes</.link>
        <h1 class="text-xl font-semibold">Development setup</h1>
        <p :if={@error} role="alert">{@error}</p>
        <div :if={@status} data-test="local-setup-status" class="space-y-3">
          <code>{@status.directory}</code>
          <p :if={@status.running}>Setup is running.</p>
          <div class="flex flex-wrap gap-2">
            <button
              :for={
                {action, label} <- [
                  {"check", "Check prerequisites"},
                  {"create", "Create app"},
                  {"connect", "Connect checkout"},
                  {"refresh", "Refresh connection"}
                ]
              }
              type="button"
              phx-click="setup"
              phx-value-action={action}
              disabled={@status.running}
              class="btn btn-sm"
            >{label}</button>
          </div>
          <p :if={@status[:result] && @status.result["error"]} role="alert">
            {@status.result["error"]}
          </p>
          <section :for={
            step <- (@status.machine_snapshot && @status.machine_snapshot["steps"]) || []
          }>
            <strong>{step["key"]}: {step["state"]}</strong>
            <p :if={step["error"]}>{step["error"]}</p>
          </section>
          <section :for={
            {name, operation} <- (@status.snapshot && @status.snapshot["operations"]) || %{}
          }>
            <strong>{name}: {operation["state"]}</strong>
            <p :if={operation["error"]}>{inspect(operation["error"])}</p>
          </section>
          <CodeMySpecWeb.AppLive.DesktopSetupResults.results snapshot={@status.machine_snapshot} />
        </div>
      </CodeMySpecWeb.ConsoleLive.Components.Shell.frame>
    </Layouts.app>
    """
  end
end
