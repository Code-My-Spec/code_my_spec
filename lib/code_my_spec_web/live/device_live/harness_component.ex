defmodule CodeMySpecWeb.DeviceLive.HarnessComponent do
  @moduledoc """
  Harness capabilities for account devices, shared by the device list and detail.

  Accepts current_scope, project_id, optional device_id/exclude_provider, and
  show_add (default true). Each update refreshes connection state. The host
  subscribes to Devices events and sends updates; successful mutations notify
  it with {:devices_changed, component_id}.
  """
  use CodeMySpecWeb, :live_component

  alias CodeMySpec.Accounts.Authorization
  alias CodeMySpec.Analysis.HarnessRegistry
  alias CodeMySpec.Devices
  alias CodeMySpec.Devices.Device
  alias CodeMySpec.Devices.RoutineFire
  alias CodeMySpec.Projects.LocalSetup
  alias CodeMySpec.WorkingCopies
  alias CodeMySpec.Workspaces
  alias CodeMySpec.Workspaces.PreviewAddress
  alias CodeMySpec.Workspaces.Runner
  alias CodeMySpecWeb.WorkingCopyLive.Liveness

  @impl true
  def render(assigns) do
    ~H"""
    <div id={@id} data-test="device-harnesses" class="w-full">
      <.flash id={"#{@id}-info"} kind={:info} flash={@flash} />
      <.flash id={"#{@id}-error"} kind={:error} flash={@flash} />
      <.button
        :if={@show_add and @can_add?}
        phx-click="new_dev_box"
        phx-target={@myself}
        data-test="add-dev-box"
      >
        Connect a device
      </.button>
      <form
        :if={@adding?}
        id="add-dev-box-form"
        data-test="add-dev-box-form"
        phx-submit="add_dev_box"
        phx-change="choose_dev_box_provider"
        phx-target={@myself}
        class="card card-compact mt-4 border border-base-300 bg-base-100"
      >
        <div class="card-body gap-3">
          <label class="form-control">
            <span class="label-text">Name</span>
            <input
              type="text"
              name="dev_box[name]"
              value={@dev_box_name}
              class="input input-bordered"
              required
            />
          </label>
          <fieldset class="flex flex-col gap-2">
            <legend class="label-text">Where it runs</legend>
            <label :for={provider <- @providers} class="flex items-center gap-2">
              <input
                type="radio"
                name="dev_box[provider]"
                value={provider.id()}
                checked={@selected_provider == to_string(provider.id())}
                data-test={"provider-#{provider.id()}"}
              />
              {provider.label()}
            </label>
          </fieldset>
          <p
            :if={@selected_provider == "codex_cloud"}
            data-test="codex-cloud-platform"
            class="text-sm"
          >
            Codex Cloud requires an x86_64 Linux image. Setup installs cms-linux-x64.tar.gz.
          </p>
          <label :if={@selected_provider == "codex_cloud"} class="form-control">
            <span class="label-text">Generation target</span>
            <select
              name="dev_box[target]"
              data-test="generation-target"
              class="select select-bordered"
            >
              <option value="phoenix">Phoenix (CodeMySpec)</option>
            </select>
          </label>
          <div class="flex gap-2">
            <.button type="submit">Add dev box</.button>
            <.button
              type="button"
              phx-click="cancel_dev_box"
              phx-target={@myself}
              class="btn btn-ghost"
            >
              Cancel
            </.button>
          </div>
        </div>
      </form>

      <div
        :if={@new_box}
        data-test="new-dev-box"
        class="card card-compact mt-4 border border-success bg-base-100"
      >
        <div class="card-body gap-3">
          <h2 class="card-title">{@new_box.name} harness access</h2>
          <p :if={Map.get(@new_box, :show_token?, true)} class="text-sm">
            This is its token. It is shown once: copy it now, because it cannot be shown again.
          </p>
          <code
            :if={Map.get(@new_box, :show_token?, true)}
            data-test="new-dev-box-token"
            data-token={@new_box.token}
            class="break-all rounded bg-base-200 p-2 text-sm"
          >
            {@new_box.token}
          </code>
          <div :for={section <- @new_box.sections} data-test={section.key} class="space-y-1">
            <div class="flex items-center justify-between gap-3">
              <h3 class="font-medium">{section.title}</h3>
              <button
                type="button"
                class="copy-btn btn btn-sm btn-primary"
                data-copy={Map.get(section, :value, section.body)}
                data-test={section.copy}
              >
                Copy
              </button>
            </div>
            <pre class="whitespace-pre-wrap rounded bg-base-200 p-2 text-xs">{section.body}</pre>
          </div>
        </div>
      </div>

      <p :if={@devices == []} data-test="devices-empty" class="py-16 text-center opacity-60">
        No harness devices yet. Connect a device, or a machine appears when a harness starts on it.
      </p>

      <ul class="mt-6 space-y-3">
        <li
          :for={row <- @devices}
          data-test="device"
          data-device-id={row.device.id}
          data-kind={row.device.kind}
          class="card card-compact border border-base-300 bg-base-100"
        >
          <div class="card-body gap-2">
            <div class="flex items-start gap-3">
              <div class="min-w-0 flex-1">
                <div data-test="device-name" class="font-medium truncate">
                  <.link
                    :if={@project_id}
                    navigate={~p"/app/projects/#{@project_id}/console/devices/#{row.device.id}"}
                  >{row.name}</.link>
                  <.link :if={!@project_id} navigate={~p"/app/devices/#{row.device.id}"}>{row.name}</.link>
                </div>
                <div
                  :if={row.device.provider == :hetzner}
                  data-test="provider-machine"
                  class="text-xs opacity-60"
                >
                  Hetzner · {row.device.provider_name}
                  <span :if={row.device.purpose}> · {row.device.purpose}</span>
                </div>
                <div data-test="device-kind" class="text-xs opacity-60">
                  {kind_name(row.device.kind)}
                </div>
              </div>

              <div
                :if={Device.dev_box?(row.device)}
                data-test="dev-box"
                data-box-name={row.name}
                data-device-id={row.device.id}
                class="shrink-0 text-right text-sm"
              >
                <span data-test="dev-box-provider">{row.provider && row.provider.label()}</span>
                <span data-test="dev-box-status">{row.status}</span>
                <a
                  :for={url <- row.previews}
                  data-test="dev-box-preview"
                  href={url}
                  target="_blank"
                  class="link"
                >
                  {url}
                </a>
                <p
                  :if={
                    row.device.provider == :claude_code_cloud and
                      is_nil(row.device.token_last_used_at) and is_nil(row.device.token_revoked_at)
                  }
                  data-test="never-connected-help"
                  class="text-xs opacity-70"
                >
                  This box has never connected. If its session started, check the
                  environment's allowlist includes {@server_host} (and the other hosts shown
                  when it was added), and that the network secret is set for {@server_host}.
                </p>
                <a
                  :if={@sessions[row.device.id]}
                  data-test="session-url"
                  href={@sessions[row.device.id]}
                  target="_blank"
                  class="link"
                >
                  Open the session
                </a>
                <.button
                  :if={
                    @can_add? and row.device.provider == :claude_code_cloud and row.startable? and
                      row.presence.label != "Present"
                  }
                  phx-click="start_box"
                  phx-target={@myself}
                  phx-value-id={row.device.id}
                  data-test="start-box"
                  data-device-id={row.device.id}
                  class="btn btn-xs btn-primary"
                >
                  Start
                </.button>
                <.button
                  :if={@can_add? and row.device.provider == :claude_code_cloud and not row.startable?}
                  phx-click="new_fire_token"
                  phx-target={@myself}
                  phx-value-id={row.device.id}
                  data-test="add-fire-token"
                  data-device-id={row.device.id}
                  class="btn btn-xs btn-ghost"
                >
                  Add a fire token
                </.button>
                <form
                  :if={@fire_form_for == row.device.id}
                  data-test="fire-token-form"
                  data-device-id={row.device.id}
                  phx-submit="save_fire_token"
                  phx-target={@myself}
                  class="mt-2 flex flex-col gap-1 text-left"
                >
                  <input type="hidden" name="device_id" value={row.device.id} />
                  <input
                    type="text"
                    name="fire_token[routine_id]"
                    placeholder="trig_…"
                    class="input input-bordered input-sm"
                  />
                  <input
                    type="password"
                    name="fire_token[token]"
                    placeholder="fire token"
                    class="input input-bordered input-sm"
                  />
                  <.button type="submit" class="btn btn-xs">Save</.button>
                </form>
                <.button
                  :if={@can_add? and is_nil(row.device.token_revoked_at)}
                  phx-click="revoke_dev_box"
                  phx-target={@myself}
                  phx-value-id={row.device.id}
                  data-test="revoke-dev-box"
                  data-device-id={row.device.id}
                  class="btn btn-xs btn-ghost"
                >
                  Revoke
                </.button>
              </div>

              <div data-test="device-presence" class="shrink-0 text-right text-sm">
                {row.presence.label}
                <span :if={row.presence.since} class="opacity-70">{row.presence.since}</span>
              </div>

              <div
                :if={row.device.provider != :hetzner}
                data-test="dev-box-up"
                class="shrink-0 text-right text-sm"
              >
                <%= if row.up? do %>
                  Up
                <% else %>
                  Down
                  <span :if={row.last_up} data-test="last-up" class="opacity-70">
                    Last up {row.last_up}
                  </span>
                <% end %>
              </div>
            </div>

            <form
              :if={@can_add? and not is_nil(@device_id)}
              phx-submit="rename_device"
              phx-target={@myself}
              data-test="rename-device"
              class="flex gap-2"
            >
              <input type="hidden" name="device_id" value={row.device.id} />
              <input
                type="text"
                name="label"
                value={row.name}
                aria-label="Device name"
                class="input input-bordered input-sm"
              />
              <.button type="submit" class="btn btn-sm btn-ghost">Rename</.button>
            </form>
            <div
              :if={@project_id && row.copies != []}
              class="flex flex-wrap gap-2"
              data-test="device-working-copies"
            >
              <.link
                :for={copy <- row.copies}
                navigate={~p"/app/projects/#{@project_id}/working-copies/#{copy.id}"}
                class="link text-sm"
              >
                {WorkingCopies.display_name(copy)}
              </.link>
            </div>
            <div class="flex flex-wrap items-center gap-2">
              <.link
                :if={@project_id && row.device.id == @local_setup_device_id}
                navigate={~p"/app/projects/#{@project_id}/console/devices/#{row.device.id}/setup"}
                class="btn btn-sm"
                data-test="device-setup"
              >Setup</.link>
              <.button
                :if={
                  @can_add? and row.device.provider == :hetzner and
                    not Device.dev_box?(row.device)
                }
                phx-click="enroll_machine"
                phx-target={@myself}
                phx-value-id={row.device.id}
                data-test="enroll-machine"
                class="btn btn-sm"
              >
                Connect harness
              </.button>
              <.button
                phx-click="revoke_authorization"
                phx-target={@myself}
                phx-value-id={row.device.id}
                data-test="revoke-device-authorization"
                class="btn btn-sm btn-ghost"
              >
                Revoke my harness access
              </.button>
              <.button
                :if={@can_add?}
                data-confirm="Remove this device and its working-copy records? Files and provider infrastructure will remain."
                phx-click="destroy"
                phx-target={@myself}
                phx-value-id={row.device.id}
                data-test="destroy-device"
                class="btn btn-sm btn-ghost"
              >
                Remove device
              </.button>
              <span class="text-xs opacity-60">
                Removes its working-copy records; files and provider infrastructure stay.
              </span>
            </div>
          </div>
        </li>
      </ul>
    </div>
    """
  end

  @impl true
  def mount(socket) do
    {:ok,
     assign(socket,
       adding?: false,
       fire_form_for: nil,
       sessions: %{},
       selected_provider: nil,
       dev_box_name: "",
       new_box: nil,
       device_id: nil,
       exclude_provider: nil,
       show_add: true
     )}
  end

  @impl true
  def update(assigns, socket) do
    socket = assign(socket, assigns)
    scope = socket.assigns.current_scope

    {:ok,
     socket
     |> assign(
       local_setup_device_id: local_setup_device_id(scope),
       providers: Runner.dev_boxes(),
       can_add?: can_add?(scope)
     )
     |> load()}
  end

  defp local_setup_device_id(scope) do
    case LocalSetup.run(scope, "status") do
      {:ok, %{device_id: id}} -> id
      _ -> nil
    end
  end

  # Owners and admins add boxes; everyone else on the account only sees them.
  defp can_add?(%{active_account_id: account_id, user: %{}} = scope) when is_binary(account_id),
    do: Authorization.authorize(:manage_account, scope, account_id)

  defp can_add?(_scope), do: false

  @impl true
  def handle_event(event, _params, %{assigns: %{can_add?: false}} = socket)
      when event in [
             "new_dev_box",
             "add_dev_box",
             "revoke_dev_box",
             "new_fire_token",
             "save_fire_token",
             "start_box",
             "enroll_machine",
             "destroy",
             "rename_device"
           ] do
    {:noreply, put_flash(socket, :error, "Only an account owner or admin can manage devices.")}
  end

  def handle_event("rename_device", %{"device_id" => id, "label" => label}, socket) do
    scope = socket.assigns.current_scope

    with %Device{} = device <- Devices.get_device(scope, id),
         {:ok, _device} <- Devices.relabel(scope, device, label) do
      {:noreply, changed(socket)}
    else
      _ -> {:noreply, put_flash(socket, :error, "Could not rename this device.")}
    end
  end

  def handle_event("new_dev_box", _params, %{assigns: %{can_add?: true}} = socket),
    do:
      {:noreply,
       assign(socket, adding?: true, new_box: nil, selected_provider: nil, dev_box_name: "")}

  def handle_event("choose_dev_box_provider", %{"dev_box" => params}, socket) do
    {:noreply,
     assign(socket, selected_provider: params["provider"], dev_box_name: params["name"] || "")}
  end

  # An add sent by someone who cannot add is refused, whether or not the page
  # offered it: the check is the context's, not the button's.
  def handle_event("add_dev_box", %{"dev_box" => params}, socket) do
    case add_box(socket.assigns.current_scope, params) do
      {:ok, box, token} ->
        server_url = CodeMySpecWeb.Endpoint.url()

        case launch(box, token, server_url) do
          :ok ->
            provider = Runner.dev_box(box.provider)

            {:noreply,
             socket
             |> assign(
               adding?: false,
               new_box: %{
                 device: box,
                 name: Device.display_name(box),
                 token: token,
                 show_token?: box.provider != :codex_cloud,
                 sections:
                   provider.instructions(%{
                     token: token,
                     server_url: server_url,
                     project_id: socket.assigns.project_id,
                     device_id: box.id,
                     target: params["target"] || "phoenix"
                   })
               }
             )
             |> changed()}

          {:error, reason} ->
            # No half-made box: a container that did not start leaves no device
            # and no token behind.
            Devices.destroy(socket.assigns.current_scope, box)
            {:noreply, socket |> put_flash(:error, launch_error(reason)) |> changed()}
        end

      {:error, :forbidden} ->
        {:noreply, put_flash(socket, :error, "Only an account owner or admin can add a dev box.")}

      {:error, :unknown_provider} ->
        {:noreply, put_flash(socket, :error, "Choose where the dev box runs.")}

      {:error, :unsupported_target} ->
        {:noreply,
         put_flash(socket, :error, "Choose a supported generation target: Phoenix (CodeMySpec).")}

      {:error, %Ecto.Changeset{}} ->
        {:noreply, put_flash(socket, :error, "Name the dev box.")}
    end
  end

  # Revoking cuts off exactly one box: its token stops signing in, the access
  # tokens already issued to it die, and its open connections are closed.
  def handle_event("revoke_dev_box", %{"id" => id}, socket) do
    case Devices.revoke_dev_box(socket.assigns.current_scope, id) do
      {:ok, box} ->
        CodeMySpec.Oauth.revoke_box_tokens(box.id)
        CodeMySpecWeb.Endpoint.broadcast("dev_box:#{box.id}", "disconnect", %{})

        {:noreply,
         socket |> put_flash(:info, "#{Device.display_name(box)} was revoked.") |> changed()}

      {:error, _reason} ->
        {:noreply,
         put_flash(socket, :error, "Only an account owner or admin can revoke a dev box.")}
    end
  end

  def handle_event("new_fire_token", %{"id" => id}, socket),
    do: {:noreply, assign(socket, fire_form_for: id)}

  def handle_event("save_fire_token", %{"device_id" => id, "fire_token" => params}, socket) do
    case Devices.set_fire_token(socket.assigns.current_scope, id, params) do
      {:ok, _box} ->
        {:noreply, socket |> assign(fire_form_for: nil) |> changed()}

      {:error, :forbidden} ->
        {:noreply,
         put_flash(socket, :error, "Only an account owner or admin can set a fire token.")}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Give the routine id (trig_…) and its fire token.")}
    end
  end

  # Fires the box's routine. One attempt: a refusal is shown, never retried.
  def handle_event("start_box", %{"id" => id}, socket) do
    case Devices.get_device(socket.assigns.current_scope, id) do
      %Device{} = box ->
        {:noreply, start_async(socket, {:fire, box.id}, fn -> RoutineFire.fire(box) end)}

      nil ->
        {:noreply, socket}
    end
  end

  def handle_event("cancel_dev_box", _params, socket),
    do: {:noreply, assign(socket, adding?: false)}

  def handle_event("enroll_machine", %{"id" => id}, socket) do
    case Devices.enroll_existing_device(socket.assigns.current_scope, id) do
      {:ok, device, token} ->
        sections = [
          %{
            key: "setup-existing-machine",
            copy: "copy-setup-existing-machine",
            title: "Start the installed harness on this machine",
            body:
              "CMS_SERVER_URL=#{CodeMySpecWeb.Endpoint.url()} CMS_DEVICE_TOKEN=#{token} cms harness"
          }
        ]

        {:noreply,
         socket
         |> assign(
           new_box: %{
             device: device,
             name: Device.display_name(device),
             token: token,
             sections: sections
           }
         )
         |> changed()}

      {:error, :already_enrolled} ->
        {:noreply, put_flash(socket, :error, "This machine already has a harness token.")}

      {:error, _reason} ->
        {:noreply,
         put_flash(socket, :error, "Only an account owner or admin can enroll this machine.")}
    end
  end

  def handle_event("destroy", %{"id" => id}, socket) do
    result =
      socket.assigns.current_scope
      |> Devices.get_device(id)
      |> destroy(socket.assigns.current_scope)

    case result do
      {:error, :in_use} ->
        {:noreply,
         socket
         |> put_flash(:error, "This machine is still assigned to an environment.")
         |> changed()}

      _ ->
        {:noreply, changed(socket)}
    end
  end

  def handle_event("revoke_authorization", %{"id" => id}, socket) do
    case CodeMySpec.Oauth.revoke_device_authorization(socket.assigns.current_scope, id) do
      {:ok, clients} ->
        Enum.each(clients, fn {application_id, user_id} ->
          CodeMySpecWeb.Endpoint.broadcast(
            "oauth_client:#{application_id}:#{user_id}",
            "disconnect",
            %{}
          )
        end)

        message =
          if clients == [],
            do: "You have no harness authorization on this device.",
            else: "Your harness access has been revoked."

        {:noreply, socket |> put_flash(:info, message) |> changed()}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Could not revoke harness access.")}
    end
  end

  @impl true
  def handle_async({:fire, id}, {:ok, {:ok, %{session_url: url}}}, socket),
    do: {:noreply, assign(socket, sessions: Map.put(socket.assigns.sessions, id, url))}

  def handle_async({:fire, _id}, {:ok, {:error, {:rate_limited, seconds}}}, socket),
    do: {:noreply, put_flash(socket, :error, rate_limited_message(seconds))}

  def handle_async({:fire, _id}, {:ok, {:error, _reason}}, socket),
    do: {:noreply, put_flash(socket, :error, "Claude did not start a session. Try again.")}

  def handle_async({:fire, _id}, {:exit, _reason}, socket),
    do: {:noreply, put_flash(socket, :error, "Claude did not start a session. Try again.")}

  # A Docker box runs on a machine that has a daemon, so adding it starts its
  # container; the others are brought up by the person from the instructions.
  defp launch(%Device{provider: :docker} = box, token, server_url),
    do: Workspaces.start_dev_box(box, token, server_url)

  defp launch(_box, _token, _server_url), do: :ok

  defp rate_limited_message(seconds) when is_integer(seconds) do
    minutes = max(div(seconds + 59, 60), 1)

    "Claude refused the start: the routine is rate-limited. Try again in about " <>
      "#{minutes} #{if minutes == 1, do: "minute", else: "minutes"}. Nothing will retry by itself."
  end

  defp rate_limited_message(_unknown),
    do:
      "Claude refused the start: the routine is rate-limited. Try again later. Nothing will retry by itself."

  defp launch_error(:docker_unreachable),
    do: "Docker is not reachable. Start Docker and add the box again."

  defp launch_error(_reason), do: "The dev box could not be started."

  defp destroy(nil, _scope), do: :ok
  defp destroy(device, scope), do: Devices.destroy(scope, device)

  defp changed(socket) do
    send(self(), {:devices_changed, socket.assigns.id})
    load(socket)
  end

  defp load(socket) do
    now = DateTime.utc_now()
    scope = socket.assigns.current_scope

    devices =
      scope
      |> Devices.list_devices()
      |> Enum.filter(fn device ->
        (is_nil(socket.assigns.device_id) or device.id == socket.assigns.device_id) and
          (is_nil(socket.assigns.exclude_provider) or
             device.provider != socket.assigns.exclude_provider)
      end)

    device_ids = Enum.map(devices, & &1.id)
    copies = WorkingCopies.ids_by_device(device_ids)

    project_copies =
      if is_binary(socket.assigns.project_id) and
           scope.active_project_id == socket.assigns.project_id,
         do: scope |> WorkingCopies.list_harnesses() |> Enum.group_by(& &1.device_id),
         else: %{}

    serving = WorkingCopies.serving_projects_by_device(device_ids)

    rows =
      for device <- devices do
        previews =
          for project_id <- Map.get(serving, device.id, []), do: PreviewAddress.url(project_id)

        row(device, Map.get(copies, device.id, []), previews, now)
        |> Map.put(:copies, Map.get(project_copies, device.id, []))
      end

    assign(socket,
      devices: rows,
      server_host: URI.parse(CodeMySpecWeb.Endpoint.url()).host,
      now: now
    )
  end

  defp row(device, copy_ids, previews, now) do
    up? = reachable?(copy_ids)

    %{
      device: device,
      copy_ids: copy_ids,
      previews: previews,
      startable?: Devices.startable?(device),
      status: box_status(device, up?),
      provider: Runner.dev_box(device.provider),
      name: Device.display_name(device),
      presence: presence(up?, device, now),
      up?: up?,
      last_up: last_up_display(device)
    }
  end

  # "Up" is this story's own claim, distinct from `presence/3`'s existing
  # Present/Last seen wording (never conflate one liveness signal with
  # another -- this page's own moduledoc rule) and from `box_status/1`
  # (whether the box's token has ever signed in at all). It reuses the same
  # connection signal `reachable?/1` already reads, per this story's own
  # notes against building a second liveness system.
  defp last_up_display(%Device{last_up_at: nil}), do: nil
  defp last_up_display(%Device{last_up_at: at}), do: Calendar.strftime(at, "%H:%M")

  # Is any of this machine's working copies holding a channel right now?
  #
  # `HarnessRegistry` is a live process per connected copy, which is the whole
  # reason to ask it rather than a column: a process cannot be stale. A machine
  # is reachable exactly while something on it is connected.
  defp reachable?(copy_ids) do
    Enum.any?(copy_ids, &match?({:ok, _pid, _instance}, HarnessRegistry.executor_holder(&1)))
  end

  # Presence is the connection; last seen is the fallback for a machine that
  # has not got one.
  #
  # This used to be a threshold on `last_seen_at` — under two minutes meant
  # Present — and it was wrong in the direction that matters. `last_seen_at` is
  # written when something happens (a manifest, an announce), so a machine that
  # is up and simply not changing files went stale while connected: observed
  # live, reading "Last seen 4m ago" against a `/health` that said
  # `connected: true` with a four-second-old reply.
  #
  # A quiet machine and an unreachable one are precisely what this page exists
  # to separate, and a timestamp cannot separate them — only the connection can.
  defp presence(true, _device, _now), do: %{label: "Present", since: nil}

  # Never heard from at all is not the same claim as having gone quiet: nothing
  # has happened yet, rather than something having stopped.
  defp presence(false, %Device{provider: :hetzner, last_seen_at: nil}, _now),
    do: %{label: "Harness not connected", since: nil}

  defp presence(false, %{last_seen_at: nil}, _now),
    do: %{label: "Not yet seen", since: nil}

  defp presence(false, %{last_seen_at: at}, now),
    do: %{label: "Last seen", since: Liveness.since(at, now)}

  # A dev box says whether anything has ever signed in with its token.
  defp box_status(%Device{token_revoked_at: %DateTime{}}, _reachable), do: "Revoked"
  defp box_status(%Device{provider: :codex_cloud}, true), do: "Connected"
  defp box_status(%Device{provider: :codex_cloud}, false), do: "Waiting for connection"
  defp box_status(%Device{token_last_used_at: nil}, _reachable), do: "Never connected"
  defp box_status(%Device{}, _reachable), do: "Connected"

  # "unknown", not a guess. A default here would make a sprite read as somebody's
  # laptop, which is the one distinction the field exists for.
  defp kind_name(:local), do: "local machine"
  defp kind_name(:cloud), do: "cloud machine"
  defp kind_name(_none), do: "unknown kind"

  defp add_box(_scope, %{"provider" => "codex_cloud", "target" => target})
       when target != "phoenix",
       do: {:error, :unsupported_target}

  defp add_box(scope, params),
    do: Devices.add_dev_box(scope, params, Runner.dev_box(params["provider"]))
end
