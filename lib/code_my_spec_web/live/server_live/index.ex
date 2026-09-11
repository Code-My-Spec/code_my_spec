defmodule CodeMySpecWeb.ServerLive.Index do
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

  alias CodeMySpec.Accounts
  alias CodeMySpec.Servers
  alias CodeMySpecWeb.ServerLive.FormComponent

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Servers")
     |> assign(:show_unlinked, false)
     |> assign(:pending, nil)
     |> assign(:server, nil)
     |> assign(:provision_error, nil)
     |> assign(:retire_error, nil)
     |> assign(:can_manage, can_manage?(socket.assigns.current_scope))
     |> load_servers()
     |> load_environments()
     |> load_options()}
  end

  # Owner/admin only — story 989's own Three Amigos decision: any member may
  # view this page, only owner/admin may create, link, or retire on it. Gated
  # here too, not only in the render, since a hidden button is not the same
  # control as one that would also refuse the event if clicked some other way.
  defp can_manage?(%{active_account_id: account_id} = scope) when is_binary(account_id) do
    Accounts.own_role(scope, account_id) in [:owner, :admin]
  end

  defp can_manage?(_scope), do: false

  @impl true
  def handle_params(params, _url, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :edit, %{"name" => name}) do
    case Servers.get_linked(socket.assigns.current_scope, name) do
      # Reachable by URL for a box that was unlinked or destroyed since the
      # link was made. Saying so beats a form bound to nothing.
      nil ->
        socket
        |> put_flash(:error, "That server is not linked to this account.")
        |> push_patch(to: ~p"/app/servers")

      server ->
        socket |> assign(:server, server) |> assign(:page_title, "Edit #{server.name}")
    end
  end

  defp apply_action(socket, _action, _params) do
    socket |> assign(:server, nil) |> assign(:page_title, "Servers")
  end

  @impl true
  def handle_info({:server_saved, _server}, socket) do
    {:noreply, socket |> load_servers() |> load_environments()}
  end

  defp load_environments(socket) do
    assign(socket, :environments, Servers.known_environments(socket.assigns.current_scope))
  end

  @impl true
  def handle_event("link", _params, %{assigns: %{can_manage: false}} = socket), do: {:noreply, socket}

  def handle_event("link", %{"name" => name}, socket) do
    case Servers.link(socket.assigns.current_scope, name) do
      {:ok, _server} -> {:noreply, load_servers(socket)}
      {:error, reason} -> {:noreply, assign(socket, :provider_error, describe(reason))}
    end
  end

  def handle_event("retire", _params, %{assigns: %{can_manage: false}} = socket), do: {:noreply, socket}

  def handle_event("retire", %{"name" => name}, socket) do
    case Servers.retire(socket.assigns.current_scope, name) do
      :ok ->
        # A patch, not a plain reassign: it is the page's own confirmation
        # that the action completed without leaving `/app/servers` — the
        # same trip the edit modal's own close button already makes.
        {:noreply,
         socket |> assign(:retire_error, nil) |> load_servers() |> push_patch(to: ~p"/app/servers")}

      {:error, {:in_use, projects}} ->
        {:noreply, assign(socket, :retire_error, %{name: name, message: in_use_message(projects)})}

      {:error, :not_found} ->
        {:noreply,
         socket |> assign(:retire_error, nil) |> load_servers() |> push_patch(to: ~p"/app/servers")}
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

  def handle_event("stage", _params, %{assigns: %{can_manage: false}} = socket), do: {:noreply, socket}

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

  def handle_event("provision", _params, %{assigns: %{can_manage: false}} = socket), do: {:noreply, socket}

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
      #
      # The linked ones still render. They are our own records, they cost money
      # whether or not we can reach the provider, and blanking them is how a box
      # leaves the screen for good — the exact failure this page exists to stop.
      {:error, reason, linked} ->
        socket
        |> assign(:servers, linked)
        |> assign(:provider_error, describe(reason))
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
      {:ok, options} -> socket |> assign(:options, options) |> assign(:location, first_location(options))
      {:error, _reason} -> socket |> assign(:options, []) |> assign(:location, nil)
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

  defp in_use_message(projects),
    do: "Still serving #{Enum.join(projects, ", ")} — point it elsewhere first, then retire it."

  defp linked(servers), do: Enum.filter(servers, & &1.linked)
  defp unlinked(servers), do: Enum.reject(servers, & &1.linked)

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      current_path={@current_path}
    >
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
          <.server_row server={server} can_manage={@can_manage} retire_error={@retire_error} />
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
            <.server_row server={server} can_manage={@can_manage} retire_error={@retire_error} />
          </div>
        </div>

        <.provision_panel
          :if={@can_manage}
          options={@options}
          location={@location}
          pending={@pending}
          error={@provision_error}
        />

        <dialog :if={@live_action == :edit and @server} id="server-form-modal" class="modal modal-open">
          <div class="modal-box max-w-lg">
            <.live_component
              module={FormComponent}
              id={@server.id}
              server={@server}
              environments={@environments}
              return_to={~p"/app/servers"}
            />
          </div>
          <form method="dialog" class="modal-backdrop">
            <button phx-click={JS.patch(~p"/app/servers")}>close</button>
          </form>
        </dialog>
      </div>
    </Layouts.app>
    """
  end

  attr :server, :map, required: true
  attr :can_manage, :boolean, default: false
  attr :retire_error, :map, default: nil

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
      <div class="card-body py-3 flex-row items-center justify-between gap-4">
        <div class="flex items-center gap-2 min-w-0">
          <%!--
            The status carries as colour rather than a word. It is the one
            field that is the same on every row and read at a glance — "running"
            spelled out on every line is noise you have to read past to find the
            one that is not. `data-status` still carries the provider's own
            word for anything reading the page.
          --%>
          <span
            data-test="server-status"
            title={@server.status || "state unknown"}
            class={["inline-block size-2.5 rounded-full shrink-0", status_colour(@server)]}
          >
          </span>

          <.link
            navigate={~p"/app/servers/#{@server.name}"}
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
            patch={~p"/app/servers/#{@server.name}/edit"}
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

  # Green only when the provider says it is up. Anything mid-flight is amber,
  # anything stopped is red, and a box we could not ask about is grey rather
  # than a colour that would imply we know.
  defp status_colour(%{missing: true}), do: "bg-error"
  defp status_colour(%{unverified: true}), do: "bg-base-content/30"
  defp status_colour(%{status: "running"}), do: "bg-success"
  defp status_colour(%{status: status}) when status in ~w(initializing starting migrating), do: "bg-warning"
  defp status_colour(%{status: nil}), do: "bg-base-content/30"
  defp status_colour(_server), do: "bg-error"

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
        data-test="provision-form"
        phx-submit="stage"
        phx-change="choose"
        class="flex flex-wrap gap-3 items-end"
      >
        <label class="form-control">
          <span class="label-text">Location</span>
          <select name="server[location]" class="select select-bordered">
            <option :for={option <- @options} value={option.location} selected={option.location == @location}>
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
