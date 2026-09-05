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
  alias CodeMySpec.WorkingCopies
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
         {:ok, counts} <- WorkingCopies.offboard(scope, row.harness) do
      {:noreply,
       socket
       |> put_flash(:info, offboarded(row, counts))
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
    case WorkingCopies.designate_main(socket.assigns.current_scope, id) do
      {:ok, _copy} ->
        {:noreply, load(socket)}

      {:error, :not_found} ->
        {:noreply, put_flash(socket, :error, "That working copy is not on this project.")}

      {:error, _changeset} ->
        {:noreply,
         put_flash(socket, :error, "That copy could not be made the main one. Try again.")}
    end
  end

  # Says what went, in counts. "Offboarded" alone leaves the reader wondering
  # whether it did anything, and the numbers are the difference between a copy
  # that was holding the project up and one that was already empty.
  defp offboarded(row, %{files: files, problems: problems, components: components} = counts) do
    "Offboarded #{row.label} — #{count(files, "file")}, #{count(problems, "problem")} " <>
      "and #{count(components, "orphaned component")} removed." <> agents(counts)
  end

  # What became of the agents, said only when there were any.
  #
  # The one that has to be said out loud is the agent that would not stop: the
  # copy is gone from here and a process may still be running on a machine, and
  # ending it is the operator's to do because the server could not reach it.
  # Silence there reads as "everything is over", which is the belief this whole
  # story exists to stop being wrong.
  defp agents(%{agents_stopped: 0, agents_left_running: []}), do: ""

  defp agents(%{agents_stopped: stopped, agents_left_running: []}),
    do: " #{count(stopped, "agent")} stopped."

  defp agents(%{agents_stopped: stopped, agents_left_running: left}) do
    " #{count(stopped, "agent")} stopped, and #{count(length(left), "agent")} could not be " <>
      "reached — #{Enum.join(left, ", ")} may still be running on its machine."
  end

  defp agents(_counts), do: ""

  # Counted nouns agree with their count. A real offboard printed "1 orphaned
  # components removed", which reads as a template rather than a report of what
  # just happened to this copy.
  defp count(1, noun), do: "1 #{noun}"
  defp count(n, noun), do: "#{n} #{noun}s"

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
            class={[
              "card card-compact",
              if(row.harness.main,
                do: "border-2 border-primary bg-primary/5",
                else: "border border-base-300 bg-base-100"
              )
            ]}
          >
            <div class="card-body gap-3">
              <%!-- The star, and nothing else, for the copy that already holds
              it. It used to be followed by "Your project's main checkout —
              its agent runs here", which is a sentence explaining a mark that
              already reads; hover and assistive text still carry the full
              meaning for anyone who wants it. Every other row gets the same
              star as a control instead — there was no way to change this
              short of opening a copy and finding the button on its own page. --%>
              <div
                :if={row.harness.main}
                data-test="main-copy"
                title="Your project's main checkout — its agent runs here"
                class="flex items-center gap-2 text-primary"
              >
                <.icon name="hero-star-solid" class="size-4" />
                <span class="sr-only">Your project's main checkout — its agent runs here</span>
              </div>

              <button
                :if={not row.harness.main}
                type="button"
                phx-click="designate_main"
                phx-value-id={row.harness.id}
                data-test="designate-main-copy"
                class="-ml-2 flex items-center gap-1 self-start text-xs opacity-50 hover:opacity-100"
              >
                <.icon name="hero-star" class="size-4" /> Make main
              </button>

              <div class="flex items-start gap-3">
                <div class="min-w-0 flex-1">
                  <%!-- `label` falls back to the raw root when nothing has
                  named this copy, and a plain CSS `truncate` cuts the *end* of
                  a string — keeping the part every checkout on this machine
                  shares (`/Users/…/Documents/github/code_my_spec/…`) and
                  hiding the one segment that tells two copies apart. Once
                  named, the path adds nothing a rename didn't already say, so
                  it is gone rather than kept underneath. --%>
                  <.link
                    navigate={~p"/app/projects/#{@project.id}/working-copies/#{row.harness.id}"}
                    data-test="open-working-copy"
                    class="block min-w-0 font-medium link link-hover"
                  >
                    <span :if={row.harness.label} class="block truncate">
                      {row.harness.label}
                    </span>
                    <.path_tail :if={!row.harness.label} path={row.harness.root} class="font-medium" />
                  </.link>

                  <%!-- Where this copy's preview answers. Only the copy that has
                  one shows one, which is the whole of "a worktree does not claim
                  to be where the preview runs" — nothing here has to say so. --%>
                  <a
                    :if={row.harness.preview_url}
                    data-test="working-copy-preview"
                    href={row.harness.preview_url}
                    target="_blank"
                    rel="noopener"
                    class="block truncate text-xs link link-hover opacity-60"
                  >
                    {URI.parse(row.harness.preview_url).host}
                  </a>

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

                  <p
                    :if={row.missing}
                    data-test="path-missing-basis"
                    class="text-xs text-warning/80"
                  >
                    Its machine reports nothing at this path. Nothing has been removed —
                    offboard it when you are sure it is not coming back.
                  </p>
                </div>

                <div data-test="liveness" class="shrink-0 text-right">
                  <%!-- Whether anything is actually serving this checkout, which
                  is not what the liveness line answers. Liveness reports what
                  the agents on the copy last said; this reports whether the
                  copy is being served at all.

                  They come apart exactly where it hurts. A harness adopts a
                  copy on its first hook request, so a checkout nobody has
                  opened a session in is served by nothing — and a worktree
                  created *for an agent* has nobody to open one. On 2026-09-04
                  a copy sat in that state for over an hour with an agent
                  assigned to it, and the only thing that ever said so was a
                  chat message failing to deliver. --%>
                  <div
                    :if={not row.served}
                    data-test="copy-not-ready"
                    class="badge badge-ghost badge-sm mb-1"
                  >
                    <.icon name="hero-signal-slash" class="size-3" /> Not being served
                  </div>
                  <span :if={row.served} data-test="copy-ready" class="sr-only">served</span>
                  <div
                    :if={row.missing}
                    data-test="path-missing"
                    class="badge badge-warning badge-sm mb-1"
                  >
                    <.icon name="hero-exclamation-triangle" class="size-3" /> Checkout gone
                    <span :if={row.missing.since} data-test="path-missing-since">
                      &nbsp;{row.missing.since}
                    </span>
                  </div>
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

              <%!-- Individual agent chips used to sit here, one per lane —
              redundant with the liveness line above it, which already says
              how many agents and what they are doing ("2 agents present on
              the harness channel"). Per-agent detail belongs to Show, where
              each lane gets its own row. --%>
              <div :if={row.last_message} class="text-xs opacity-60">
                <span data-test="last-message">last message {row.last_message}</span>
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

                <button
                  type="button"
                  data-test="offboard-working-copy"
                  data-working-copy-id={row.harness.id}
                  class="btn btn-sm btn-ghost text-error"
                  phx-click={show_confirm("offboard-#{row.harness.id}")}
                >
                  <.icon name="hero-trash" /> Offboard
                </button>

                <.confirm_dialog
                  id={"offboard-#{row.harness.id}"}
                  title="Offboard this working copy?"
                  message={
                    "Removes #{row.label} and everything derived from it — its files, " <>
                      "its problems, and any component left with nothing pointing at it. " <>
                      "The checkout on disk is not touched."
                  }
                  confirm_label="Offboard"
                  on_confirm={JS.push("offboard", value: %{id: row.harness.id})}
                />
              </div>
            </div>
          </li>
        </ul>
      </div>
    </Layouts.app>
    """
  end
end
