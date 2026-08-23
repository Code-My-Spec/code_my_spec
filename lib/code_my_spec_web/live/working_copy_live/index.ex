defmodule CodeMySpecWeb.WorkingCopyLive.Index do
  @moduledoc """
  Every working copy on the project, and what is running on each.

  A harness is a working copy — `WorkingCopies.issue/3` mints one id per checkout,
  so "harness id" and "working copy id" are the same thing. The list is the set
  of copies, not the set of agents: a checkout running nothing is still a row,
  because a copy that is absent reads as a copy that does not exist.

  ## What a row says, and why it says the basis

  Each row carries a verdict *and* the signal behind it — "Running · 2 agents
  present on the harness channel · 40s ago". A bare "Present" is the page
  asserting something with the evidence removed, and it cannot tell a lane that
  checked in two seconds ago from one that checked in an hour ago.

  ## Reading only

  No forms here. Renaming a copy is `WorkingCopyLive.Form`, on its own route,
  because a list with an edit box on every row is a page where the thing you
  came to read is the smallest part of what is on screen — and where a stray
  return key renames a checkout.

  Talking to an agent is `AgentConversationLive.Show`, which already exists and
  already renders the transcript. A second, worse transcript inlined here would
  be a second place to look for one conversation.

  ## What this page does not do

  It does not start or stop anything, and that is a decision rather than an
  omission. A harness is installed and runs on its own machine; lifecycle
  belongs where the process is. `Agents.stop_agent/2` exists and is deliberately
  not wired to any surface here.
  """

  use CodeMySpecWeb, :live_view

  alias CodeMySpec.Agents
  alias CodeMySpecWeb.WorkingCopyLive.Rows

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, :page_title, "Working copies")}
  end

  @impl true
  def handle_params(_params, _uri, socket) do
    case socket.assigns[:project] do
      nil ->
        {:noreply,
         socket
         |> put_flash(:error, "That project is not yours, or does not exist.")
         |> push_navigate(to: ~p"/app/projects")}

      _project ->
        if connected?(socket) do
          Agents.subscribe(socket.assigns.current_scope)
          schedule_tick()
        end

        {:noreply, load(socket)}
    end
  end

  # Re-read on any agent news. The page's whole claim is about what is running
  # right now, and a report is the only moment the server learns an agent went.
  @impl true
  def handle_info({event, _payload}, socket)
      when event in [:agents_reported, :agent_started, :agent_stopped] do
    {:noreply, load(socket)}
  end

  # Re-render on a timer as well as on news. Every liveness line is elapsed
  # time computed at render, so a page that only redraws when an agent moves
  # shows "Running just now" for as long as nothing happens — the one reading
  # that cannot be true after the first minute.
  def handle_info(:tick, socket) do
    schedule_tick()
    {:noreply, load(socket)}
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  # Matches `LaneReporter`'s heartbeat: redrawing faster than the facts arrive
  # invents precision the page does not have.
  defp schedule_tick, do: Process.send_after(self(), :tick, :timer.seconds(30))

  defp load(socket) do
    rows =
      Rows.list(
        socket.assigns.current_scope,
        socket.assigns.project,
        DateTime.utc_now()
      )

    assign(socket, :rows, rows)
  end

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
      <div data-test="working-copies" class="mx-auto w-full max-w-3xl">
        <.header>
          Working copies
          <:subtitle>
            Every checkout serving this project, and the agents running on it. A working
            copy is a harness — same id, two names.
          </:subtitle>
        </.header>

        <p :if={@rows == []} data-test="working-copies-empty" class="py-16 text-center opacity-60">
          No working copies yet. One appears when a harness connects for this project.
        </p>

        <ul class="mt-6 space-y-3">
          <li
            :for={row <- @rows}
            data-test="working-copy"
            data-working-copy-id={row.harness.id}
            data-root={row.harness.root}
            class="card card-compact border border-base-300 bg-base-100"
          >
            <div class="card-body gap-3">
              <div class="flex items-start gap-3">
                <div class="min-w-0 flex-1">
                  <.link
                    navigate={~p"/app/projects/#{@project.id}/working-copies/#{row.harness.id}"}
                    data-test="open-working-copy"
                    class="block truncate font-medium link link-hover"
                  >
                    {row.label}
                  </.link>
                  <div class="text-xs opacity-60 truncate">
                    <span data-test="working-copy-id" class="font-mono">
                      {short_id(row.harness.id)}
                    </span>
                    {row.harness.root}
                  </div>

                  <div class="text-xs opacity-60 truncate">
                    <span
                      :if={row.device}
                      data-test="working-copy-device"
                      data-device-id={row.device.id}
                    >
                      on {row.device_name}
                    </span>
                    <span :if={is_nil(row.device)} data-test="working-copy-no-device">
                      no machine — never reported one, or it may be orphaned
                    </span>
                  </div>
                </div>

                <div data-test="liveness" class="shrink-0 text-right">
                  <div class="text-sm">
                    {row.liveness.label}
                    <span :if={row.liveness.since} data-test="liveness-since" class="opacity-70">
                      {row.liveness.since}
                    </span>
                  </div>
                  <div data-test="liveness-basis" class="text-xs opacity-60">
                    {row.liveness.basis}
                  </div>
                </div>
              </div>

              <div class="flex flex-wrap items-center gap-2 text-xs">
                <span
                  :for={agent <- row.agents}
                  data-test="agent-chip"
                  data-role={agent.role}
                  data-engine={agent.engine}
                  class="badge badge-ghost"
                >
                  {agent.role} · {engine_name(agent.engine)}
                </span>

                <span :if={row.last_message} data-test="last-message" class="opacity-60">
                  last message {row.last_message}
                </span>
              </div>

              <div class="flex items-center gap-2">
                <.button
                  navigate={~p"/app/projects/#{@project.id}/working-copies/#{row.harness.id}"}
                  class="btn btn-sm"
                  data-test="view-working-copy"
                >
                  View
                </.button>
                <.button
                  navigate={~p"/app/projects/#{@project.id}/working-copies/#{row.harness.id}/edit"}
                  class="btn btn-sm btn-ghost"
                  data-test="edit-working-copy"
                >
                  <.icon name="hero-pencil-square" /> Rename
                </.button>
              </div>
            </div>
          </li>
        </ul>
      </div>
    </Layouts.app>
    """
  end

  defp engine_name(:pi), do: "Pi"
  defp engine_name(:claude_code), do: "Claude Code"
  defp engine_name(other), do: to_string(other)

  # The one thing on the row that is always unique.
  #
  # A checkout that joins without presenting an id is minted a new one, and it
  # reports its root afterwards — so one real directory can hold several harness
  # rows with the same generated label, the same path and the same status.
  # Whether that should happen at all is a question about identity across
  # machines and is not settled here; what is settled is that the page stops
  # rendering rows a person cannot tell apart. Same reason
  # `AgentConversationLive.Index` prints the session id beside the name: the
  # name is a handle, and the id is what you go and grep for.
  defp short_id(id) when is_binary(id), do: String.slice(id, 0, 8)
  defp short_id(_id), do: "????????"
end
