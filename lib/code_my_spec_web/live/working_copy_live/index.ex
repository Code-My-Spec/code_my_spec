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
  belongs where the process is. `Agents.turn_off_agent/3` exists and is deliberately
  not wired to any surface here.

  ## The one thing it does remove

  Offboarding, and only when asked. A copy whose machine reports nothing at its
  root is shown as gone and left completely alone — story 892 used to reclaim
  that state automatically after a couple of quiet hours, and the signal it
  trusted went stale while agents worked, so it came within one sync of deleting
  two mid-session agents' files. Now the page says what it was told and waits
  for somebody who knows.

  Offboarding never touches the checkout on disk. It removes the row and what
  was derived from it.
  """

  use CodeMySpecWeb, :live_view

  alias CodeMySpec.Agents
  alias CodeMySpec.Staffing
  alias CodeMySpecWeb.WorkingCopyLive.Components.Copy
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
          Agents.subscribe_presence(socket.assigns.current_scope)
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

  # An agent's process came up or went down (`Agents.Presence`).
  def handle_info(%Phoenix.Socket.Broadcast{event: "presence_diff"}, socket),
    do: {:noreply, load(socket)}

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

  @doc """
  Remove a working copy and everything derived from it.

  The one destructive act on this page, and the only thing that removes a
  working copy at all — nothing does it on a timer any more.

  Found through the project's own list rather than by a bare id lookup, because
  the id arrives from the client. `Rows.get/4` answers only for copies on the
  scope's project, so an id belonging to somebody else finds nothing and is
  refused — the same shape every other action on this page uses.
  """
  @impl true
  def handle_event("offboard", %{"id" => id}, socket) do
    scope = socket.assigns.current_scope

    with row when not is_nil(row) <-
           Rows.get(scope, socket.assigns.project, id, DateTime.utc_now()),
         {:ok, counts} <- Staffing.offboard(scope, row.harness) do
      {:noreply,
       socket
       |> put_flash(:info, Copy.offboarded(row, counts))
       |> load()}
    else
      _ ->
        {:noreply, put_flash(socket, :error, "That working copy is not on this project.")}
    end
  end

  # Designating this checkout as the one the project's own agent runs in.
  #
  # Lifted from `WorkingCopyLive.Show`, which still carries the same handler —
  # there was previously no way to do this without opening a copy first.
  def handle_event("designate_main", %{"id" => id}, socket) do
    case Staffing.designate_main(socket.assigns.current_scope, id) do
      {:ok, _copy} ->
        {:noreply, load(socket)}

      {:error, :not_found} ->
        {:noreply, put_flash(socket, :error, "That working copy is not on this project.")}

      {:error, _changeset} ->
        {:noreply,
         put_flash(socket, :error, "That copy could not be made the main one. Try again.")}
    end
  end

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
          <li :for={row <- @rows}>
            <Copy.facts
              row={row}
              class={[
                "rounded-box p-4",
                if(row.harness.main,
                  do: "border-2 border-primary bg-primary/5",
                  else: "border border-base-300 bg-base-100"
                )
              ]}
            >
              <:title>
                <div class="flex items-center gap-2">
                  <span
                    :if={row.harness.main}
                    data-test="main-copy"
                    title="Your project's main checkout — its agent runs here"
                    class="flex shrink-0 text-primary"
                  >
                    <.icon name="hero-star-solid" class="size-4" />
                    <span class="sr-only">Your project's main checkout — its agent runs here</span>
                  </span>
                  <.link
                    navigate={~p"/app/projects/#{@project.id}/working-copies/#{row.harness.id}"}
                    data-test="open-working-copy"
                    class="min-w-0 flex-1 truncate font-medium link link-hover"
                  >
                    {row.heading}
                  </.link>
                  <button
                    :if={not row.harness.main}
                    type="button"
                    phx-click="designate_main"
                    phx-value-id={row.harness.id}
                    data-test="designate-main-copy"
                    class="flex shrink-0 items-center gap-1 text-xs opacity-50 hover:opacity-100"
                  >
                    <.icon name="hero-star" class="size-4" /> Make main
                  </button>
                </div>
              </:title>
              <:actions>
                <.link
                  navigate={~p"/app/projects/#{@project.id}/working-copies/#{row.harness.id}/status"}
                  class="btn btn-sm btn-ghost"
                  data-test="working-copy-status"
                >
                  Status
                </.link>
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
                <Copy.offboard row={row} />
              </:actions>
            </Copy.facts>
          </li>
        </ul>
      </div>
    </Layouts.app>
    """
  end
end
