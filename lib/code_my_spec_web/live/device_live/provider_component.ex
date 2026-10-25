defmodule CodeMySpecWeb.DeviceLive.ProviderComponent do
  @moduledoc """
  Provider inventory within Devices. Discovery remains visible even for machines
  not linked to the account; provider failures never imply an empty inventory.

  | Assign | Type | Required | Description |
  | --- | --- | --- | --- |
  | id | string | yes | Component identity |
  | current_scope | Scope | yes | Account and permission scope |
  | project_id | UUID or nil | no | Console project |
  | devices_path | string | yes | Canonical Devices URL |
  | edit_name | string or nil | no | Provider machine whose purpose is being edited |
  | connected_device_ids | list | no | Machine UUIDs with live harness connections |
  | refresh | term | no | Change to refresh provider inventory |
  | saved_server | Device | no | Partial update after local purpose save; no provider requests |

  Link, retirement and provisioning events enforce owner/admin permissions.
  Purpose saves emit `{:server_saved, device}` to the parent LiveView.
  """

  use CodeMySpecWeb, :live_component

  alias CodeMySpec.Accounts
  alias CodeMySpec.Servers
  alias CodeMySpecWeb.ServerLive.FormComponent

  @impl true
  def update(%{saved_server: device}, socket) do
    servers =
      Enum.map(socket.assigns.servers, fn server ->
        if server.device_id == device.id,
          do: Map.put(server, :environment, device.purpose),
          else: server
      end)

    {:ok,
     socket
     |> assign(:servers, servers)
     |> load_environments()
     |> edit_server()}
  end

  def update(assigns, socket) do
    reload? =
      not Map.has_key?(socket.assigns, :servers) or
        Map.get(assigns, :refresh) != Map.get(socket.assigns, :refresh) or
        Map.get(assigns, :current_scope, socket.assigns[:current_scope]) !=
          socket.assigns[:current_scope]

    socket =
      socket
      |> assign_new(:show_unlinked, fn -> false end)
      |> assign_new(:pending, fn -> nil end)
      |> assign_new(:server, fn -> nil end)
      |> assign_new(:provision_error, fn -> nil end)
      |> assign_new(:retire_error, fn -> nil end)
      |> assign_new(:edit_name, fn -> nil end)
      |> assign_new(:project_id, fn -> nil end)
      |> assign_new(:connected_device_ids, fn -> [] end)
      |> assign(assigns)

    {:ok,
     socket
     |> assign(:can_manage, can_manage?(socket.assigns.current_scope))
     |> refresh_inventory(reload?)
     |> edit_server()}
  end

  defp refresh_inventory(socket, false), do: socket

  defp refresh_inventory(socket, true),
    do: socket |> load_servers() |> load_environments() |> load_options()

  defp edit_server(%{assigns: %{edit_name: nil}} = socket),
    do: assign(socket, server: nil, edit_error: nil)

  defp edit_server(socket) do
    server = Servers.get_linked(socket.assigns.current_scope, socket.assigns.edit_name)

    socket
    |> assign(:server, server)
    |> assign(:edit_error, if(is_nil(server), do: "That server is not linked to this account."))
  end

  # Owner/admin only — story 989's own Three Amigos decision: any member may
  # view this page, only owner/admin may create, link, or retire on it. Gated
  # here too, not only in the render, since a hidden button is not the same
  # control as one that would also refuse the event if clicked some other way.
  defp can_manage?(%{active_account_id: account_id} = scope) when is_binary(account_id) do
    Accounts.own_role(scope, account_id) in [:owner, :admin]
  end

  defp can_manage?(_scope), do: false

  defp load_environments(socket) do
    assign(socket, :environments, Servers.known_environments(socket.assigns.current_scope))
  end

  @impl true
  def handle_event("link", _params, %{assigns: %{can_manage: false}} = socket),
    do: {:noreply, socket}

  def handle_event("link", %{"name" => name}, socket) do
    case Servers.link(socket.assigns.current_scope, name) do
      {:ok, _server} ->
        send(self(), :provider_inventory_changed)
        {:noreply, load_servers(socket)}

      {:error, reason} ->
        {:noreply, provider_error(socket, reason)}
    end
  end

  def handle_event("retire", _params, %{assigns: %{can_manage: false}} = socket),
    do: {:noreply, socket}

  def handle_event("retire", %{"name" => name}, socket) do
    case Servers.retire(socket.assigns.current_scope, name) do
      :ok ->
        send(self(), :provider_inventory_changed)

        # A patch, not a plain reassign: it is the page's own confirmation
        # that the action completed without leaving the Devices inventory — the
        # same trip the edit modal's own close button already makes.
        {:noreply,
         socket
         |> assign(:retire_error, nil)
         |> load_servers()
         |> push_patch(to: socket.assigns.devices_path)}

      {:error, {:in_use, projects}} ->
        {:noreply,
         assign(socket, :retire_error, %{name: name, message: in_use_message(projects)})}

      {:error, :not_found} ->
        {:noreply,
         socket
         |> assign(:retire_error, nil)
         |> load_servers()
         |> push_patch(to: socket.assigns.devices_path)}

      {:error, reason} ->
        {:noreply, assign(socket, :retire_error, %{name: name, message: describe_retire(reason)})}
    end
  end

  def handle_event("toggle-unlinked", _params, socket) do
    {:noreply, assign(socket, :show_unlinked, !socket.assigns.show_unlinked)}
  end

  # Re-narrows the size list when the location changes. Availability is per
  # location, so the sizes on offer have to follow it or the form invites pairs
  # that cannot be built.
  def handle_event("choose", %{"server" => %{"location" => location}}, socket) do
    {:noreply, socket |> assign(:location, location) |> assign(:pending, nil)}
  end

  def handle_event("stage", _params, %{assigns: %{can_manage: false}} = socket),
    do: {:noreply, socket}

  # Choosing is free. This only stages what was chosen and shows the cost —
  # criterion 8267 is that nothing exists at the provider until Sam confirms.
  def handle_event("stage", %{"server" => attrs}, socket) do
    case staged(attrs, socket.assigns.options) do
      # No price means the pair is not one the provider offers. Saying so is
      # the whole of criterion 8266; the alternative was a confirm button
      # beside an empty "€/hour", which is consent to an unstated cost.
      %{hourly: nil} = pending ->
        {:noreply,
         socket
         |> assign(:pending, nil)
         |> assign(:provision_error, unavailable_pair(pending))}

      pending ->
        {:noreply, socket |> assign(:pending, pending) |> assign(:provision_error, nil)}
    end
  end

  def handle_event("provision", _params, %{assigns: %{can_manage: false}} = socket),
    do: {:noreply, socket}

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
        send(self(), :provider_inventory_changed)
        {:noreply, socket |> assign(:pending, nil) |> load_servers()}

      {:error, reason} ->
        {:noreply, assign(socket, :provision_error, describe_provision(reason, pending))}
    end
  end

  defp provider_error(socket, reason) do
    assign(socket, provider_error: describe(reason), provider_error_reason: reason)
  end

  defp load_servers(socket) do
    case Servers.list(socket.assigns.current_scope) do
      {:ok, servers} ->
        socket
        |> assign(:servers, servers)
        |> assign(provider_error: nil, provider_error_reason: nil)
        |> expand_when_nothing_linked(servers)

      # Not an empty list. "You have no servers" and "we could not ask" are
      # different facts, and only one of them is safe to imply.
      #
      # The linked ones still render. They are our own records, they cost money
      # whether or not we can reach the provider, and blanking them is how a box
      # leaves the screen for good — the exact failure this page exists to stop.
      {:error, reason, linked} ->
        socket
        |> assign(:servers, linked)
        |> provider_error(reason)
        |> expand_when_nothing_linked(linked)
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
      {:ok, options} ->
        socket |> assign(:options, options) |> assign(:location, first_location(options))

      {:error, _reason} ->
        socket |> assign(:options, []) |> assign(:location, nil)
    end
  end

  defp first_location([%{location: location} | _]), do: location
  defp first_location(_), do: nil

  defp staged(%{"size" => size, "location" => location}, options) do
    type =
      options
      |> Enum.find(%{types: []}, &(&1.location == location))
      |> Map.get(:types)
      |> Enum.find(&(&1.name == size))

    %{size: size, location: location, hourly: type && type.hourly, type: type}
  end

  defp unavailable_pair(%{size: size, location: location}),
    do:
      "#{size} is not available in #{location} right now, so there is no price to quote. " <>
        "Pick another location or another size — nothing was created."

  # A credential that was never supplied is not an outage. Saying "could not
  # reach the provider" sends Sam to Hetzner's status page for a problem that
  # is entirely on this side, and retrying will never fix it.
  defp describe(:hetzner_not_configured),
    do: "No Hetzner API token is connected for this account. Add one to see your servers."

  defp describe(:provider_identity_conflict),
    do: "The provider replaced this machine. Review its identity before linking it again."

  defp describe(:not_linked),
    do: "That server is not linked to this account, so there is nowhere to record what it is for."

  defp describe(:unauthorized), do: "The provider refused the credential (unauthorized)."
  defp describe(:timeout), do: "The provider could not be reached before timing out."
  defp describe(reason) when is_binary(reason), do: reason
  defp describe(reason), do: "Could not reach the provider: #{inspect(reason)}"

  defp describe_provision({:capacity_unavailable, where}, _pending),
    do: "#{where} is unavailable right now. Nothing was created."

  defp describe_provision(:ssh_key_required, pending),
    do:
      "#{pending.size} in #{pending.location} was not created: no SSH key could be prepared, " <>
        "and a server without one cannot be reached after it boots."

  defp describe_provision(reason, pending),
    do: "#{pending.size} in #{pending.location} could not be created: #{describe(reason)}"

  defp describe_retire(:in_use),
    do: "A project still uses this machine. Move its environment first."

  defp describe_retire(reason), do: "Could not retire this machine: #{inspect(reason)}"

  defp in_use_message(projects),
    do: "Still serving #{Enum.join(projects, ", ")} — point it elsewhere first, then retire it."

  defp linked(servers), do: Enum.filter(servers, & &1.linked)
  defp unlinked(servers), do: Enum.reject(servers, & &1.linked)

  @impl true
  def render(assigns) do
    ~H"""
    <section id={@id} class="mt-8" aria-label="Hetzner devices">
      <h2 class="text-lg font-semibold mb-4">Hetzner devices</h2>
      <p :if={assigns[:edit_error]} role="alert" class="alert alert-error mb-4">{@edit_error}</p>
      <div
        :if={@provider_error}
        data-test="provider-error"
        role={if @provider_error_reason == :hetzner_not_configured, do: "status", else: "alert"}
        class={[
          "alert alert-soft mb-6",
          if(@provider_error_reason == :hetzner_not_configured, do: "alert-info", else: "alert-error")
        ]}
      >
        <span>{@provider_error}</span>
        <.link
          :if={@provider_error_reason == :hetzner_not_configured && @project_id && @can_manage}
          navigate={"/app/projects/#{@project_id}/console/credentials"}
          class="btn btn-sm btn-ghost"
          data-test="configure-provider"
        >
          Connect Hetzner (optional)
        </.link>
      </div>

      <div :for={server <- linked(@servers)} class="mb-2">
        <.server_row
          server={server}
          can_manage={@can_manage}
          retire_error={@retire_error}
          account_id={@current_scope.active_account_id}
          devices_path={@devices_path}
          target={@myself}
          connected_device_ids={@connected_device_ids}
        />
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
        phx-target={@myself}
        class="btn btn-ghost btn-sm my-4"
      >
        {if @show_unlinked, do: "Hide", else: "+#{length(unlinked(@servers))} more"} not linked
      </button>

      <div :if={@show_unlinked} data-test="unlinked-servers">
        <div :for={server <- unlinked(@servers)} class="mb-2">
          <.server_row
            server={server}
            can_manage={@can_manage}
            retire_error={@retire_error}
            account_id={@current_scope.active_account_id}
            devices_path={@devices_path}
            target={@myself}
            connected_device_ids={@connected_device_ids}
          />
        </div>
      </div>

      <.provision_panel
        :if={@can_manage && @provider_error_reason != :hetzner_not_configured}
        options={@options}
        location={@location}
        pending={@pending}
        error={@provision_error}
        target={@myself}
      />

      <dialog
        :if={@edit_name && @server && @can_manage}
        id="server-form-modal"
        class="modal modal-open"
      >
        <div class="modal-box max-w-lg">
          <.live_component
            module={FormComponent}
            id={@server.id}
            server={@server}
            environments={@environments}
            current_scope={@current_scope}
            return_to={@devices_path}
          />
        </div>
        <form method="dialog" class="modal-backdrop">
          <button phx-click={JS.patch(@devices_path)}>close</button>
        </form>
      </dialog>
    </section>
    """
  end

  attr :server, :map, required: true
  attr :can_manage, :boolean, default: false
  attr :retire_error, :map, default: nil
  attr :account_id, :string, default: nil
  attr :devices_path, :string, required: true
  attr :target, :any, required: true
  attr :connected_device_ids, :list, default: []

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
      data-unverified={to_string(@server.unverified)}
      data-environment={@server.environment}
      class={[
        "card bg-base-200",
        @server.missing && "border border-error",
        @server.unverified && "border border-warning"
      ]}
    >
      <div class="card-body py-3 flex-col sm:flex-row sm:items-center justify-between gap-4">
        <div class="flex flex-wrap items-center gap-2 min-w-0">
          <span
            data-test="server-status"
            title={"Provider status: #{@server.status || "unknown"}"}
            class={["inline-block size-2.5 rounded-full shrink-0", status_colour(@server)]}
          ></span>

          <.link
            navigate={detail_path(@devices_path, @server)}
            data-test="open-server"
            class="font-mono link link-hover"
          >
            {@server.name}
          </.link>
          <span
            :if={@server.environment}
            data-test="server-environment"
            class="badge badge-primary badge-sm"
          >
            {@server.environment}
          </span>
          <%!--
            a654ed04: the label above is Sam's own words and nothing points at
            it being wrong either way; this is the actual answer to "is
            anything relying on this box", read from the real links rather
            than from what the label happens to say.
          --%>
          <span data-test="server-linked-projects" class="text-xs opacity-60">
            {linked_projects_label(@account_id, @server.name)}
          </span>
          <span class="text-xs" data-test="provider-status-label">
            Provider: {@server.status || "unknown"}
          </span>
          <span :if={@server.linked} class="text-xs" data-test="provider-harness-status">
            {if @server.device_id in @connected_device_ids,
              do: "Harness connected",
              else: "Harness not connected"}
          </span>
          <span
            :if={@server[:identity_conflict]}
            class="badge badge-error badge-sm"
            data-test="provider-identity-conflict"
          >
            Provider replaced this machine; identity needs review
          </span>
          <span :if={@server.ip} class="text-xs opacity-70">{@server.ip}</span>
          <span :if={@server.size} class="badge badge-ghost badge-sm">{@server.size}</span>
          <span :if={@server.missing} class="badge badge-error badge-sm">
            missing at provider
          </span>
          <span :if={@server.unverified} class="badge badge-warning badge-sm">
            state unavailable
          </span>
        </div>

        <button
          :if={not @server.linked and @can_manage}
          type="button"
          data-test="link-server"
          phx-click="link"
          phx-target={@target}
          phx-value-name={@server.name}
          class="btn btn-sm btn-primary"
        >
          Link
        </button>

        <div :if={@server.linked} class="flex items-center gap-2">
          <%!--
            The label is our record of Sam's answer, and a server he has not
            claimed has nowhere to keep one — hence gated on @server.linked,
            same as retiring.
          --%>
          <.link
            :if={@can_manage}
            patch={"#{@devices_path}/provider/#{URI.encode_www_form(@server.name)}/edit"}
            data-test="edit-server"
            class="btn btn-sm btn-ghost"
          >
            Edit
          </.link>

          <button
            :if={@can_manage}
            type="button"
            data-test="retire-server"
            phx-click="retire"
            phx-target={@target}
            phx-value-name={@server.name}
            class="btn btn-sm btn-ghost text-error"
          >
            Retire
          </button>
        </div>
      </div>

      <div
        :if={@retire_error && @retire_error.name == @server.name}
        data-test="retire-error"
        role="alert"
        class="alert alert-error alert-soft mx-4 mb-3"
      >
        <span>{@retire_error.message}</span>
      </div>
    </div>
    """
  end

  defp detail_path(base, %{device_id: id}) when is_binary(id), do: "#{base}/#{id}"
  defp detail_path(base, server), do: "#{base}/provider/#{URI.encode_www_form(server.name)}"

  # Green only when the provider says it is up. Anything mid-flight is amber,
  # anything stopped is red, and a box we could not ask about is grey rather
  # than a colour that would imply we know.
  defp status_colour(%{missing: true}), do: "bg-error"
  defp status_colour(%{unverified: true}), do: "bg-base-content/30"
  defp status_colour(%{status: "running"}), do: "bg-success"

  defp status_colour(%{status: status}) when status in ~w(initializing starting migrating),
    do: "bg-warning"

  defp status_colour(%{status: nil}), do: "bg-base-content/30"
  defp status_colour(_server), do: "bg-error"

  # The real answer to "does anything point at this box", read from
  # `environments` rather than from the purpose label above —
  # which can say anything and link to nothing (a654ed04).
  defp linked_projects_label(nil, _name), do: "not used by any project"

  defp linked_projects_label(account_id, name) do
    case Servers.environments_on(account_id, name) do
      [] ->
        "not used by any project"

      entries ->
        entries
        |> Enum.map(&"#{&1.project.name} / #{&1.environment}")
        |> Enum.sort()
        |> Enum.join(", ")
    end
  end

  attr :target, :any, required: true
  attr :options, :list, required: true
  attr :location, :string, default: nil
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

      <form
        id="provision-form"
        data-test="provision-form"
        phx-target={@target}
        phx-submit="stage"
        phx-change="choose"
        class="flex flex-wrap gap-3 items-end"
      >
        <label class="form-control">
          <span class="label-text">Location</span>
          <select name="server[location]" class="select select-bordered">
            <option
              :for={option <- @options}
              value={option.location}
              selected={option.location == @location}
            >
              {option.city} ({option.location})
            </option>
          </select>
        </label>

        <label class="form-control">
          <span class="label-text">Size</span>
          <select name="server[size]" data-test="size-options" class="select select-bordered">
            <option :for={type <- types_in(@options, @location)} value={type.name}>
              {type.name} — {type.cores} vCPU, {type.memory}GB, {type.disk}GB ({type.architecture})
              — €{type.hourly}/hr
            </option>
          </select>
        </label>

        <button type="submit" class="btn">Check</button>
      </form>

      <div :if={@pending} class="mt-4 flex items-center gap-4">
        <span data-test="provision-cost" class="text-sm">
          {@pending.size} in {@pending.location} — €{@pending.hourly}/hour
        </span>

        <button
          type="button"
          data-test="provision-confirm"
          phx-click="provision"
          phx-target={@target}
          class="btn btn-primary btn-sm"
        >
          Create it
        </button>
      </div>

      <div
        :if={@error}
        data-test="provision-error"
        role="alert"
        class="alert alert-error alert-soft mt-4"
      >
        <span>{@error}</span>
      </div>
    </section>
    """
  end

  # Scoped to the chosen location, never flattened across all of them.
  # Availability is a fact about one location: `cpx11` exists in ash and hil
  # and nowhere else, `cpx12` in the other four. A flattened list offered 21
  # sizes against every location when none has more than 16, so most of the
  # pairs it permitted could not be built.
  defp types_in(options, location) do
    options
    |> Enum.find(%{types: []}, &(&1.location == location))
    |> Map.get(:types)
  end
end
