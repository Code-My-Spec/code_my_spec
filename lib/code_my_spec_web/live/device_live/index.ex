defmodule CodeMySpecWeb.DeviceLive.Index do
  @moduledoc """
  Every dev box on this account — a machine running a harness — and what is on
  each, in the console's Development section.

  One level above `WorkingCopyLive.Index`. That page lists checkouts and this
  one lists the machines they sit on, which is what turns 105 rows into a
  handful you can actually read.

  Account-scoped, not project-scoped, because a machine is not a property of a
  project — one laptop serves checkouts of several — and a device page nested
  under a project would either lie or repeat itself.

  ## Three liveness questions, and this page owns exactly one

  A **device** is present when its harness holds a connection. A **working
  copy** is present when its path still exists on that device. An **agent** is
  present when its lane is joined and working. Only the middle one had ever
  been built.

  Presence here is read from `HarnessRegistry` — a live process per connected
  working copy — rather than from a timestamp. A timestamp records when
  something last happened, which is not the same as whether the machine can be
  reached now, and the difference showed up immediately: a box that was up and
  not changing files read as stale.

  The rule this page must not break is presenting its own signal as one of the
  others. Story 957 shipped that conflation twice — `Liveness` calling a
  `:starting` agent "Running · present on the harness channel", and
  `chattable?` offering a chat to a lane that had never confirmed — both from
  reading one signal as another. So a machine here says **Present** or **Last
  seen**, and never "running", which is a claim about agents.

  ## Reading and naming, and one destructive act

  No stopping agents, no reaching onto the box. Destroying is here because it is
  a real thing that happens to a sprite, and because the alternative — a
  machine that is gone staying on the list forever — is worse. It is careful
  about what it takes with it: the checkouts stay, orphaned, because they were
  real and were worked in, and the record should not vanish because the box did.
  """

  use CodeMySpecWeb, :live_view

  alias CodeMySpec.Accounts.Authorization
  alias CodeMySpec.Analysis.HarnessRegistry
  alias CodeMySpec.Devices
  alias CodeMySpec.Devices.Device
  alias CodeMySpec.WorkingCopies
  alias CodeMySpec.Workspaces
  alias CodeMySpec.Workspaces.Runner
  alias CodeMySpecWeb.ConsoleLive.Components.Shell
  alias CodeMySpecWeb.WorkingCopyLive.Liveness

  @impl true
  def mount(params, _session, socket) do
    scope = socket.assigns.current_scope

    if connected?(socket) and is_binary(scope.active_account_id),
      do: Devices.subscribe(scope.active_account_id)

    {:ok,
     assign(socket,
       page_title: "Dev boxes",
       project_id: params["project_id"],
       adding?: false,
       new_box: nil,
       providers: Runner.dev_boxes(),
       can_add?: can_add?(scope)
     )}
  end

  # Owners and admins add boxes; everyone else on the account only sees them.
  defp can_add?(%{active_account_id: account_id, user: %{}} = scope) when is_binary(account_id),
    do: Authorization.authorize(:manage_account, scope, account_id)

  defp can_add?(_scope), do: false

  @impl true
  def handle_params(_params, _uri, socket), do: {:noreply, load(socket)}

  @impl true
  def handle_event("new_dev_box", _params, %{assigns: %{can_add?: true}} = socket),
    do: {:noreply, assign(socket, adding?: true, new_box: nil)}

  # An add sent by someone who cannot add is refused, whether or not the page
  # offered it: the check is the context's, not the button's.
  def handle_event("add_dev_box", %{"dev_box" => params}, socket) do
    case Devices.add_dev_box(
           socket.assigns.current_scope,
           params,
           Runner.dev_box(params["provider"])
         ) do
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
                 sections: provider.instructions(%{token: token, server_url: server_url})
               }
             )
             |> load()}

          {:error, reason} ->
            # No half-made box: a container that did not start leaves no device
            # and no token behind.
            Devices.destroy(socket.assigns.current_scope, box)
            {:noreply, socket |> put_flash(:error, launch_error(reason)) |> load()}
        end

      {:error, :forbidden} ->
        {:noreply, put_flash(socket, :error, "Only an account owner or admin can add a dev box.")}

      {:error, :unknown_provider} ->
        {:noreply, put_flash(socket, :error, "Choose where the dev box runs.")}

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
         socket |> put_flash(:info, "#{Device.display_name(box)} was revoked.") |> load()}

      {:error, _reason} ->
        {:noreply,
         put_flash(socket, :error, "Only an account owner or admin can revoke a dev box.")}
    end
  end

  def handle_event("cancel_dev_box", _params, socket),
    do: {:noreply, assign(socket, adding?: false)}

  def handle_event("destroy", %{"id" => id}, socket) do
    socket.assigns.current_scope
    |> Devices.get_device(id)
    |> destroy(socket.assigns.current_scope)

    {:noreply, load(socket)}
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

        {:noreply, socket |> put_flash(:info, message) |> load()}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Could not revoke harness access.")}
    end
  end

  @impl true
  def handle_info({:dev_box_connected, _id}, socket), do: {:noreply, load(socket)}
  def handle_info({:dev_box_revoked, _id}, socket), do: {:noreply, load(socket)}

  # A Docker box runs on a machine that has a daemon, so adding it starts its
  # container; the others are brought up by the person from the instructions.
  defp launch(%Device{provider: :docker} = box, token, server_url),
    do: Workspaces.start_dev_box(box, token, server_url)

  defp launch(_box, _token, _server_url), do: :ok

  defp launch_error(:docker_unreachable),
    do: "Docker is not reachable. Start Docker and add the box again."

  defp launch_error(_reason), do: "The dev box could not be started."

  defp destroy(nil, _scope), do: :ok
  defp destroy(device, scope), do: Devices.destroy(scope, device)

  defp load(socket) do
    now = DateTime.utc_now()
    scope = socket.assigns.current_scope

    devices = Devices.list_devices(scope)
    copies = devices |> Enum.map(& &1.id) |> WorkingCopies.ids_by_device()

    assign(socket,
      devices: Enum.map(devices, &row(&1, Map.get(copies, &1.id, []), now)),
      now: now
    )
  end

  defp row(device, copy_ids, now) do
    %{
      device: device,
      status: box_status(device),
      provider: Runner.dev_box(device.provider),
      name: Device.display_name(device),
      presence: presence(reachable?(copy_ids), device, now)
    }
  end

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
  defp presence(false, %{last_seen_at: nil}, _now),
    do: %{label: "Not yet seen", since: nil}

  defp presence(false, %{last_seen_at: at}, now),
    do: %{label: "Last seen", since: Liveness.since(at, now)}

  # A dev box says whether anything has ever signed in with its token.
  defp box_status(%Device{token_revoked_at: %DateTime{}}), do: "Revoked"
  defp box_status(%Device{token_last_used_at: nil}), do: "Never connected"
  defp box_status(%Device{}), do: "Connected"

  # "unknown", not a guess. A default here would make a sprite read as somebody's
  # laptop, which is the one distinction the field exists for.
  defp kind_name(:local), do: "local machine"
  defp kind_name(:cloud), do: "cloud machine"
  defp kind_name(_none), do: "unknown kind"

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      project={assigns[:project]}
      projects={assigns[:projects] || []}
    >
      <Shell.frame project_id={@project_id} active={:dev_boxes}>
        <div data-test="devices" class="mx-auto w-full max-w-3xl">
          <.header>
            Dev boxes
            <:subtitle>
              Every machine running a harness for this account. Add a dev box here, or a
              machine onboards itself when its harness comes up.
            </:subtitle>
            <:actions>
              <.button :if={@can_add?} phx-click="new_dev_box" data-test="add-dev-box">
                Add
              </.button>
            </:actions>
          </.header>

          <form
            :if={@adding?}
            id="add-dev-box-form"
            data-test="add-dev-box-form"
            phx-submit="add_dev_box"
            class="card card-compact mt-4 border border-base-300 bg-base-100"
          >
            <div class="card-body gap-3">
              <label class="form-control">
                <span class="label-text">Name</span>
                <input type="text" name="dev_box[name]" class="input input-bordered" required />
              </label>
              <fieldset class="flex flex-col gap-2">
                <legend class="label-text">Where it runs</legend>
                <label :for={provider <- @providers} class="flex items-center gap-2">
                  <input
                    type="radio"
                    name="dev_box[provider]"
                    value={provider.id()}
                    data-test={"provider-#{provider.id()}"}
                  />
                  {provider.label()}
                </label>
              </fieldset>
              <div class="flex gap-2">
                <.button type="submit">Add dev box</.button>
                <.button type="button" phx-click="cancel_dev_box" class="btn btn-ghost">
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
              <h2 class="card-title">{@new_box.name} added</h2>
              <p class="text-sm">
                This is its token. It is shown once: copy it now, because it cannot be shown again.
              </p>
              <code
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
                    data-copy={section.body}
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
            No dev boxes yet. Add one, or a machine appears when a harness starts on it.
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
                    <div data-test="device-name" class="font-medium truncate">{row.name}</div>
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
                    <.button
                      :if={@can_add? and is_nil(row.device.token_revoked_at)}
                      phx-click="revoke_dev_box"
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
                </div>

                <div class="flex items-center gap-2">
                  <.button
                    phx-click="revoke_authorization"
                    phx-value-id={row.device.id}
                    data-test="revoke-device-authorization"
                    class="btn btn-sm btn-ghost"
                  >
                    Revoke my harness access
                  </.button>
                  <.button
                    phx-click="destroy"
                    phx-value-id={row.device.id}
                    data-test="destroy-device"
                    class="btn btn-sm btn-ghost"
                  >
                    Destroy
                  </.button>
                  <span class="text-xs opacity-60">
                    its checkouts stay, with no machine
                  </span>
                </div>
              </div>
            </li>
          </ul>
        </div>
      </Shell.frame>
    </Layouts.app>
    """
  end
end
