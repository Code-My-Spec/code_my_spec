defmodule CodeMySpecWeb.ServersLive do
  @moduledoc """
  Every box the account owns, linked or not, at `/app/servers`.

  ## Why unlinked servers are collapsed and not omitted

  A box nobody can see is a box that keeps billing. Linking is how Sam says a
  server matters to him; it must not become how a server disappears. So the
  unlinked ones sit behind a count that is always visible, and the count is
  rendered whether or not anyone expands it.

  ## Why the provisioning form is built from the provider

  `/server_types` is a catalogue, not an inventory — during QA every ARM type
  was listed and not deprecated while sold out in all six datacenters. Offering
  from the catalogue offers something nobody can buy, so the form is built from
  `/datacenters`, which reports what each location can actually supply. A size
  that cannot be created is not on the screen to be chosen.

  That leaves one real race: a size available when the page loaded and gone by
  the time Sam confirms. It surfaces as an error naming the size and location,
  and nothing is retried at a different size — a silent fallback is how you pay
  for a machine you did not choose.
  """

  use CodeMySpecWeb, :live_view

  alias CodeMySpec.Servers

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Servers")
     |> assign(:show_unlinked, false)
     |> assign(:pending, nil)
     |> assign(:provision_error, nil)
     |> load_servers()
     |> load_options()}
  end

  @impl true
  def handle_event("link", %{"name" => name}, socket) do
    case Servers.link(socket.assigns.current_scope, name) do
      {:ok, _server} -> {:noreply, load_servers(socket)}
      {:error, reason} -> {:noreply, assign(socket, :provider_error, describe(reason))}
    end
  end

  def handle_event("toggle-unlinked", _params, socket) do
    {:noreply, assign(socket, :show_unlinked, !socket.assigns.show_unlinked)}
  end

  # Choosing is free. This only stages what was chosen and shows the cost —
  # criterion 8267 is that nothing exists at the provider until Sam confirms.
  def handle_event("stage", %{"server" => attrs}, socket) do
    {:noreply,
     socket
     |> assign(:pending, staged(attrs, socket.assigns.options))
     |> assign(:provision_error, nil)}
  end

  def handle_event("provision", _params, %{assigns: %{pending: nil}} = socket) do
    {:noreply, socket}
  end

  def handle_event("provision", _params, socket) do
    pending = socket.assigns.pending

    case Servers.provision(socket.assigns.current_scope, %{
           size: pending.size,
           location: pending.location
         }) do
      {:ok, _server} ->
        {:noreply, socket |> assign(:pending, nil) |> load_servers()}

      {:error, reason} ->
        {:noreply, assign(socket, :provision_error, describe_provision(reason, pending))}
    end
  end

  defp load_servers(socket) do
    case Servers.list(socket.assigns.current_scope) do
      {:ok, servers} ->
        socket
        |> assign(:servers, servers)
        |> assign(:provider_error, nil)
        |> expand_when_nothing_linked(servers)

      # Not an empty list. "You have no servers" and "we could not ask" are
      # different facts, and only one of them is safe to imply.
      {:error, reason} ->
        socket |> assign(:servers, []) |> assign(:provider_error, describe(reason))
    end
  end

  # Collapsing is about de-emphasising the unlinked *relative to* the linked.
  # With nothing linked there is nothing to de-emphasise, and hiding everything
  # behind "+5 more" would greet a new account with an empty screen and a
  # number — while the servers it is hiding are the very ones Sam came to find.
  defp expand_when_nothing_linked(socket, servers) do
    if Enum.any?(servers, & &1.linked) do
      socket
    else
      assign(socket, :show_unlinked, true)
    end
  end

  defp load_options(socket) do
    case Servers.available_options(socket.assigns.current_scope) do
      {:ok, options} -> assign(socket, :options, options)
      {:error, _reason} -> assign(socket, :options, [])
    end
  end

  defp staged(%{"size" => size, "location" => location}, options) do
    type =
      options
      |> Enum.find(%{types: []}, &(&1.location == location))
      |> Map.get(:types)
      |> Enum.find(&(&1.name == size))

    %{size: size, location: location, hourly: type && type.hourly, type: type}
  end

  defp describe(:unauthorized), do: "The provider refused the credential (unauthorized)."
  defp describe(:timeout), do: "The provider could not be reached before timing out."
  defp describe(reason) when is_binary(reason), do: reason
  defp describe(reason), do: "Could not reach the provider: #{inspect(reason)}"

  defp describe_provision({:capacity_unavailable, where}, _pending),
    do: "#{where} is unavailable right now. Nothing was created."

  defp describe_provision(reason, pending),
    do: "#{pending.size} in #{pending.location} could not be created: #{describe(reason)}"

  defp linked(servers), do: Enum.filter(servers, & &1.linked)
  defp unlinked(servers), do: Enum.reject(servers, & &1.linked)

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="mx-auto max-w-5xl">
        <h1 class="text-2xl font-semibold mb-1">Servers</h1>
        <p class="text-base-content/70 mb-6">
          Every box in your account, whether CodeMySpec made it or you did.
        </p>

        <div
          :if={@provider_error}
          data-test="provider-error"
          role="alert"
          class="alert alert-error alert-soft mb-6"
        >
          <span>{@provider_error}</span>
        </div>

        <div :for={server <- linked(@servers)} class="mb-2">
          <.server_row server={server} />
        </div>

        <p
          :if={@servers == [] and is_nil(@provider_error)}
          data-test="no-servers"
          class="text-base-content/60 my-6"
        >
          No servers in this account yet.
        </p>

        <button
          :if={unlinked(@servers) != []}
          type="button"
          data-test="unlinked-count"
          data-count={length(unlinked(@servers))}
          phx-click="toggle-unlinked"
          class="btn btn-ghost btn-sm my-4"
        >
          {if @show_unlinked, do: "Hide", else: "+#{length(unlinked(@servers))} more"} not linked
        </button>

        <div :if={@show_unlinked} data-test="unlinked-servers">
          <div :for={server <- unlinked(@servers)} class="mb-2">
            <.server_row server={server} />
          </div>
        </div>

        <.provision_panel options={@options} pending={@pending} error={@provision_error} />
      </div>
    </Layouts.app>
    """
  end

  attr :server, :map, required: true

  defp server_row(assigns) do
    ~H"""
    <div
      data-test="server"
      data-name={@server.name}
      data-ip={@server.ip}
      data-size={@server.size}
      data-status={@server.status}
      data-linked={to_string(@server.linked)}
      data-missing={to_string(@server.missing)}
      class={["card bg-base-200", @server.missing && "border border-error"]}
    >
      <div class="card-body py-3 flex-row items-center justify-between gap-4">
        <div>
          <span class="font-mono">{@server.name}</span>
          <span :if={@server.ip} class="text-xs opacity-70 ml-2">{@server.ip}</span>
          <span :if={@server.size} class="badge badge-ghost badge-sm ml-2">{@server.size}</span>
          <span :if={@server.status} class="badge badge-sm ml-1">{@server.status}</span>
          <span :if={@server.missing} class="badge badge-error badge-sm ml-1">
            missing at provider
          </span>
        </div>

        <button
          :if={not @server.linked}
          type="button"
          data-test="link-server"
          phx-click="link"
          phx-value-name={@server.name}
          class="btn btn-sm btn-primary"
        >
          Link
        </button>
      </div>
    </div>
    """
  end

  attr :options, :list, required: true
  attr :pending, :map, default: nil
  attr :error, :string, default: nil

  defp provision_panel(assigns) do
    ~H"""
    <section class="mt-10 border-t pt-6">
      <h2 class="text-lg font-semibold mb-1">New server</h2>
      <p class="text-base-content/70 text-sm mb-4">
        Only sizes the provider can actually supply right now are listed — a catalogue entry
        that is sold out is not an option you can pick.
      </p>

      <form data-test="provision-form" phx-submit="stage" class="flex flex-wrap gap-3 items-end">
        <label class="form-control">
          <span class="label-text">Location</span>
          <select name="server[location]" class="select select-bordered">
            <option :for={option <- @options} value={option.location}>
              {option.city} ({option.location})
            </option>
          </select>
        </label>

        <label class="form-control">
          <span class="label-text">Size</span>
          <select name="server[size]" class="select select-bordered">
            <option :for={type <- available_types(@options)} value={type.name}>
              {type.name} — {type.cores} vCPU, {type.memory}GB, {type.disk}GB ({type.architecture})
            </option>
          </select>
        </label>

        <button type="submit" class="btn">Check</button>
      </form>

      <div :if={@pending} class="mt-4 flex items-center gap-4">
        <span data-test="provision-cost" class="text-sm">
          {@pending.size} in {@pending.location} — €{@pending.hourly}/hour
        </span>

        <button type="button" data-test="provision-confirm" phx-click="provision" class="btn btn-primary btn-sm">
          Create it
        </button>
      </div>

      <div :if={@error} data-test="provision-error" role="alert" class="alert alert-error alert-soft mt-4">
        <span>{@error}</span>
      </div>
    </section>
    """
  end

  # Flattened across locations for the size list. The form re-checks the pair
  # on submit, so a size shown for one location cannot be bought in another.
  defp available_types(options) do
    options
    |> Enum.flat_map(& &1.types)
    |> Enum.uniq_by(& &1.name)
    |> Enum.sort_by(& &1.hourly)
  end
end
