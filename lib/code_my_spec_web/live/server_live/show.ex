defmodule CodeMySpecWeb.ServerLive.Show do
  @moduledoc """
  One server at `/app/servers/:name` — what is running on it, and what setup
  put there.

  ## Two halves, two sources, and the page says which

  The records came from us and are already in the database. The container list
  comes from the box and requires a machine to be listening. Presenting them as
  one undifferentiated list would let a stale record sit next to a live reading
  with nothing to tell them apart.

  ## Why the box is read off the mount

  A box that refuses a connection fails fast. One that accepts a connection and
  then stops answering does not fail at all, and a mount that waits on it takes
  down the half of the page that needed no network. So the records render
  immediately and the container read happens in the background, with
  `Containers` owning a deadline of its own — a spinner that never resolves is
  the same failure as a hang with better manners.

  ## Never-run is not failed

  Backups that were never switched on and backups that broke send Sam to
  different places, and backups is the step nobody notices is off until the day
  it matters. `provisioning_steps.state` already separates them; this page's
  job is not to collapse them back together.
  """

  use CodeMySpecWeb, :live_view

  alias CodeMySpec.Provisioning.ServerView
  alias CodeMySpec.Servers

  @impl true
  def mount(%{"name" => name}, _session, socket) do
    case Servers.get(socket.assigns.current_scope, name) do
      {:ok, server} ->
        {:ok,
         socket
         |> assign(:page_title, server.name)
         |> assign(:server, server)
         |> assign(:entries, ServerView.for_server(socket.assigns.current_scope, server.name))
         |> assign(:containers, :loading)
         |> assign(:containers_error, nil)
         |> read_containers(server)}

      {:error, :not_found} ->
        {:ok,
         socket
         |> put_flash(:error, "No server named #{name} in this account.")
         |> push_navigate(to: ~p"/app/servers")}
    end
  end

  # Only once connected. The static render has nowhere to deliver the result
  # to, and starting a read that will be thrown away costs the box an SSH
  # session per page load for nothing.
  defp read_containers(socket, server) do
    if connected?(socket) do
      # Bound out here rather than reached for inside the closure: the task
      # must not hold the socket, and capturing it would keep a whole LiveView
      # state alive for as long as an unresponsive box takes to time out.
      scope = socket.assigns.current_scope

      start_async(socket, :containers, fn -> Servers.containers(scope, server) end)
    else
      socket
    end
  end

  @impl true
  def handle_async(:containers, {:ok, {:ok, containers}}, socket) do
    {:noreply, socket |> assign(:containers, containers) |> assign(:containers_error, nil)}
  end

  def handle_async(:containers, {:ok, {:error, reason}}, socket) do
    {:noreply, socket |> assign(:containers, []) |> assign(:containers_error, describe(reason))}
  end

  # The task itself died. Reporting it as an empty box would be the same lie as
  # any other failure to ask.
  def handle_async(:containers, {:exit, reason}, socket) do
    {:noreply,
     socket
     |> assign(:containers, [])
     |> assign(:containers_error, describe({:crashed, reason}))}
  end

  defp describe(:no_access_key),
    do:
      "This account has no server access key yet, so there is nothing to log in with. " <>
        "One is created the first time CodeMySpec provisions a server."

  # The normal state of a box Sam built himself. Worth saying plainly, because
  # it is fixed by pasting one line rather than by debugging anything.
  defp describe(:not_permitted),
    do:
      "This box has not given CodeMySpec access. Add the account's public key to " <>
        "root's authorized_keys on the server to see what is running on it."

  defp describe(:timeout),
    do: "The box accepted the connection but did not answer in time, so we stopped waiting."

  defp describe(:unreachable),
    do: "Could not reach the box — the connection was refused or the address is unroutable."

  defp describe(:no_docker), do: "The box answered, but has no Docker installed."
  defp describe(:no_address), do: "The provider reports no address for this server."
  defp describe({:ssh_failed, status, output}), do: "SSH exited #{status}: #{output}"
  defp describe({:crashed, reason}), do: "Reading the box failed: #{inspect(reason)}"
  defp describe(reason), do: "Could not read the box: #{inspect(reason)}"

  defp state_label(:not_started), do: "never run"
  defp state_label(state), do: state |> to_string() |> String.replace("_", " ")

  defp state_class(:done), do: "bg-success"
  defp state_class(:errored), do: "bg-error"
  defp state_class(:running), do: "bg-warning"
  defp state_class(_state), do: "bg-base-content/30"

  defp container_class("running"), do: "bg-success"
  defp container_class("restarting"), do: "bg-warning"
  defp container_class("created"), do: "bg-warning"
  defp container_class(_state), do: "bg-error"

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="mx-auto max-w-5xl">
        <.link navigate={~p"/app/servers"} class="text-sm opacity-70">← Servers</.link>

        <div data-test="server-detail" data-name={@server.name} class="mt-2 mb-8">
          <h1 class="text-2xl font-semibold flex items-center gap-2">
            <span class="font-mono">{@server.name}</span>
            <span :if={@server.environment} class="badge badge-primary badge-sm">
              {@server.environment}
            </span>
          </h1>
          <p class="text-base-content/70 mt-1 text-sm">
            <span :if={@server.ip}>{@server.ip}</span>
            <span :if={@server.size} class="ml-2">{@server.size}</span>
            <span :if={@server.status} class="ml-2">{@server.status}</span>
            <span :if={@server.unverified} class="ml-2 text-warning">state unavailable</span>
          </p>
        </div>

        <section class="mb-10">
          <h2 class="text-lg font-semibold mb-1">Running</h2>
          <p class="text-base-content/70 text-sm mb-4">
            Read from the box each time this page loads — not from what the last deploy recorded.
          </p>

          <p :if={@containers == :loading} data-test="containers-pending" class="text-sm opacity-70">
            Reading the box…
          </p>

          <div
            :if={@containers_error}
            data-test="containers-error"
            role="alert"
            class="alert alert-warning alert-soft"
          >
            <span>{@containers_error}</span>
          </div>

          <p
            :if={@containers == [] and is_nil(@containers_error)}
            data-test="no-containers"
            class="text-base-content/60"
          >
            The box answered, and nothing is running on it.
          </p>

          <div :if={is_list(@containers)} class="space-y-2">
            <div
              :for={container <- @containers}
              data-test="container"
              data-name={container.name}
              data-state={container.state}
              data-status={container.status}
              data-image={container.image}
              data-exit-code={container.exit_code}
              class={[
                "card bg-base-200",
                container.state != "running" && "border border-error"
              ]}
            >
              <div class="card-body py-3 flex-row items-center gap-3">
                <span class={[
                  "inline-block size-2.5 rounded-full shrink-0",
                  container_class(container.state)
                ]}>
                </span>
                <span class="font-mono">{container.name}</span>
                <span class="text-xs opacity-70">{container.image}</span>
                <span class="ml-auto text-xs">{container.status}</span>
              </div>
            </div>
          </div>
        </section>

        <section>
          <h2 class="text-lg font-semibold mb-1">Set up here</h2>
          <p class="text-base-content/70 text-sm mb-4">
            What setup recorded against this box. These are our records, not a reading of the machine.
          </p>

          <p :if={@entries == []} data-test="no-entries" class="text-base-content/60">
            Nothing points at this server. Nothing deploys to it, and nothing was made for it.
          </p>

          <div :for={entry <- @entries} class="mb-8">
            <h3 class="font-medium mb-2">
              {entry.project_name}
              <span class="badge badge-ghost badge-sm ml-1">{entry.environment}</span>
            </h3>

            <%!--
              The error lives inside the step it belongs to, not in a list
              underneath. A failure separated from the thing that failed makes
              the reader match them up by name, and on a box carrying several
              projects there is more than one candidate.
            --%>
            <div class="flex flex-wrap gap-2 mb-3">
              <div
                :for={step <- entry.steps}
                data-test="step"
                data-key={step.key}
                data-state={step.state}
                class={[
                  "badge badge-outline gap-1",
                  step.state == :errored && "badge-error badge-outline h-auto py-1"
                ]}
              >
                <span class={["inline-block size-2 rounded-full", state_class(step.state)]}></span>
                <span>{step.key}: {state_label(step.state)}</span>
                <span :if={step.provider_error} class="text-xs opacity-80 max-w-md">
                  — {step.provider_error}
                </span>
              </div>
            </div>

            <ul class="text-sm space-y-1">
              <li
                :for={resource <- entry.resources}
                data-test="resource"
                data-kind={resource.kind}
                data-location={resource.location}
                class="flex gap-2"
              >
                <span class="badge badge-ghost badge-sm">{resource.kind}</span>
                <span class="font-mono opacity-80">{resource.location}</span>
              </li>
            </ul>
          </div>
        </section>
      </div>
    </Layouts.app>
    """
  end

end
