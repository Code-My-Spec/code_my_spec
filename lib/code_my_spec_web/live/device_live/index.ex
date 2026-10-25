defmodule CodeMySpecWeb.DeviceLive.Index do
  @moduledoc "Account machines and provider inventory, with harness and infrastructure controls together."
  use CodeMySpecWeb, :live_view

  alias CodeMySpec.Analysis.HarnessRegistry
  alias CodeMySpec.Devices
  alias CodeMySpec.WorkingCopies
  alias CodeMySpecWeb.ConsoleLive.Components.Shell
  alias CodeMySpecWeb.DeviceLive.HarnessComponent
  alias CodeMySpecWeb.DeviceLive.ProviderComponent

  @impl true
  def mount(params, _session, socket) do
    scope = socket.assigns.current_scope

    if connected?(socket) and is_binary(scope.active_account_id),
      do: Devices.subscribe(scope.active_account_id)

    {:ok,
     assign(socket,
       page_title: "Devices",
       project_id: params["project_id"],
       devices_path: base(params),
       edit_name: nil,
       connected_device_ids: connected_devices(scope),
       provider_refresh: 0,
       refresh: 0
     )}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply,
     assign(socket, :edit_name, if(socket.assigns.live_action == :edit, do: params["name"]))}
  end

  @impl true
  def handle_info({:server_saved, server}, socket) do
    send_update(ProviderComponent, id: "provider-inventory", saved_server: server)
    refresh(socket)
  end

  def handle_info(:provider_inventory_changed, socket), do: refresh_provider(socket)
  def handle_info({:devices_changed, _component}, socket), do: refresh(socket)
  def handle_info({:device_changed, _device}, socket), do: refresh(socket)
  def handle_info({:device_created, _device}, socket), do: refresh(socket)
  def handle_info({:device_deleted, _device}, socket), do: refresh(socket)

  def handle_info({event, _device}, socket)
      when event in [:dev_box_connected, :dev_box_revoked, :device_runtime_changed],
      do: refresh(socket)

  def handle_info(_message, socket), do: {:noreply, socket}

  defp refresh_provider(socket), do: refresh(update(socket, :provider_refresh, &(&1 + 1)))

  defp refresh(socket) do
    {:noreply,
     socket
     |> assign(:connected_device_ids, connected_devices(socket.assigns.current_scope))
     |> update(:refresh, &(&1 + 1))}
  end

  defp connected_devices(scope) do
    scope
    |> Devices.list_devices()
    |> Enum.map(& &1.id)
    |> WorkingCopies.ids_by_device()
    |> Enum.filter(fn {_id, copies} ->
      Enum.any?(copies, &match?({:ok, _, _}, HarnessRegistry.executor_holder(&1)))
    end)
    |> Enum.map(&elem(&1, 0))
  end

  defp base(%{"project_id" => project_id}), do: "/app/projects/#{project_id}/console/devices"
  defp base(_params), do: "/app/devices"

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      project={assigns[:project]}
      projects={assigns[:projects] || []}
    >
      <Shell.frame project_id={@project_id} active={:devices}>
        <div data-test="devices" class="mx-auto w-full max-w-6xl space-y-8">
          <.header>
            Devices
            <:subtitle>Machines, what they run, and how they connect.</:subtitle>
          </.header>
          <.live_component
            module={HarnessComponent}
            id="device-harnesses"
            current_scope={@current_scope}
            project_id={@project_id}
            exclude_provider={:hetzner}
            show_add={true}
            refresh={@refresh}
          />
          <.live_component
            module={ProviderComponent}
            id="provider-inventory"
            current_scope={@current_scope}
            project_id={@project_id}
            devices_path={@devices_path}
            connected_device_ids={@connected_device_ids}
            edit_name={@edit_name}
            refresh={@provider_refresh}
          />
        </div>
      </Shell.frame>
    </Layouts.app>
    """
  end
end
