defmodule CodeMySpecWeb.DeviceLive.Index do
  @moduledoc """
  Every machine on this account, and what is on each.

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

  alias CodeMySpec.Analysis
  alias CodeMySpec.Devices
  alias CodeMySpec.Devices.Device
  alias CodeMySpecWeb.WorkingCopyLive.Liveness

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, :page_title, "Devices")}
  end

  @impl true
  def handle_params(_params, _uri, socket), do: {:noreply, load(socket)}

  @impl true
  def handle_event("destroy", %{"id" => id}, socket) do
    socket.assigns.current_scope
    |> Devices.get_device(id)
    |> destroy(socket.assigns.current_scope)

    {:noreply, load(socket)}
  end

  defp destroy(nil, _scope), do: :ok
  defp destroy(device, scope), do: Devices.destroy(scope, device)

  defp load(socket) do
    now = DateTime.utc_now()
    scope = socket.assigns.current_scope

    assign(socket,
      devices: Enum.map(Devices.list_devices(scope), &row(&1, now)),
      now: now
    )
  end

  defp row(device, now) do
    %{
      device: device,
      name: Device.display_name(device),
      presence: presence(device, now)
    }
  end

  # Is any of this machine's working copies holding a channel right now?
  #
  # `HarnessRegistry` is a live process per connected copy, which is the whole
  # reason to ask it rather than a column: a process cannot be stale. A machine
  # is reachable exactly while something on it is connected.
  defp reachable?(device) do
    device.working_copies
    |> Enum.any?(fn copy -> match?({:ok, _pid, _instance}, Analysis.executor_holder(copy.id)) end)
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
  defp presence(device, now) do
    presence(reachable?(device), device, now)
  end

  defp presence(true, _device, _now), do: %{label: "Present", since: nil}

  # Never heard from at all is not the same claim as having gone quiet: nothing
  # has happened yet, rather than something having stopped.
  defp presence(false, %{last_seen_at: nil}, _now),
    do: %{label: "Not yet seen", since: nil}

  defp presence(false, %{last_seen_at: at}, now),
    do: %{label: "Last seen", since: Liveness.since(at, now)}

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
      pending_notifications={@pending_notifications}
      project={assigns[:project]}
      projects={assigns[:projects] || []}
    >
      <div data-test="devices" class="mx-auto w-full max-w-3xl">
        <.header>
          Devices
          <:subtitle>
            Every machine running a harness for this account. A machine onboards itself
            when its harness comes up.
          </:subtitle>
        </.header>

        <p :if={@devices == []} data-test="devices-empty" class="py-16 text-center opacity-60">
          No machines yet. One appears when a harness starts on it.
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

                <div data-test="device-presence" class="shrink-0 text-right text-sm">
                  {row.presence.label}
                  <span :if={row.presence.since} class="opacity-70">{row.presence.since}</span>
                </div>
              </div>

              <div class="flex items-center gap-2">
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
    </Layouts.app>
    """
  end
end
